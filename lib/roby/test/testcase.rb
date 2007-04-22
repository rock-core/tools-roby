require 'active_support/core_ext/string/inflections'
class String # :nodoc: all
    include ActiveSupport::CoreExtensions::String::Inflections
end

require 'roby/test/common'
require 'roby/app'
require 'fileutils'

module Roby
    module Test
	extend Logger::Hierarchy
	extend Logger::Forward

	@event_assertions = []
	@waiting_threads  = []

	ASSERT_ANY_EVENTS_TLS = :assert_any_events

	class << self
	    # A [thread, cv, positive, negative] list of event assertions
	    attr_reader :event_assertions

	    # Tests for events in +positive+ and +negative+ and returns
	    # the set of failing events if the assertion has finished.
	    # If the set is empty, it means that the assertion finished
	    # successfully
	    def assert_any_event_result(positive, negative)
		if positive.any? { |ev| ev.happened? }
		    return []
		else
		    failure = negative.find_all { |ev| ev.happened? }
		    unless failure.empty?
			return failure
		    end
		end

		nil
	    end

	    # This method is inserted in the control thread to implement
	    # Assertions#assert_events
	    def check_event_assertions
		event_assertions.delete_if do |thread, cv, positive, negative|
		    if result = assert_any_event_result(positive, negative)
			thread[ASSERT_ANY_EVENTS_TLS] = result
			cv.broadcast
			true
		    end
		end
	    end

	    def finalize_event_assertions
		check_event_assertions
		event_assertions.dup.each do |thread, *_|
		    thread.raise ControlQuitError
		end
	    end

	    # A set of threads waiting for something to happen. This is used
	    # during #teardown to make sure no threads are block indefinitely
	    attr_reader :waiting_threads

	    # This proc is to be called by Control when it quits. It makes sure
	    # that threads which are waiting are interrupted
	    def interrupt_waiting_threads
		waiting_threads.dup.each do |task|
		    task.raise ControlQuitError
		end
	    ensure
		waiting_threads.clear
	    end

	    def sampling(duration, period, *fields)
		Test.info "starting sampling #{fields.join(", ")} every #{period}s for #{duration}s"

		samples = Array.new
		fields.map! { |n| n.to_sym }
		if fields.include?(:dt)
		    raise ArgumentError, "dt is reserved by #sampling"
		end

		if compute_time = !fields.include?(:t)
		    fields << :t
		end
		fields << :dt
		
		sample_type = Struct.new(*fields)

		start = Time.now
		Roby.condition_variable(true) do |cv, mt|
		    first_sample = nil
		    mt.synchronize do
			id = Roby::Control.every(period) do
			    result = yield
			    if result
				if compute_time
				    result << Roby.control.cycle_start
				end
				new_sample = sample_type.new(*result)

				unless samples.empty?
				    new_sample.dt = new_sample.t- samples.last.t
				end
				samples << new_sample

				if samples.last.t - samples.first.t > duration
				    mt.synchronize do
					cv.broadcast
				    end
				end
			    end
			end

			cv.wait(mt)
			Roby::Control.remove_periodic_handler(id)
		    end
		end

		samples
	    end

	    Stat = Struct.new :total, :count, :mean, :stddev, :max

	    # Computes mean and standard deviation about the samples in
	    # +samples+ +spec+ describes what to compute:
	    # * if nothing is specified, we compute the statistics on
	    #     v(i - 1) - v(i)
	    # * if spec['fieldname'] is 'rate', we compute the statistics on
	    #	  (v(i - 1) - v(i)) / (t(i - 1) / t(i))
	    # * if spec['fieldname'] is 'absolute', we compute the
	    #   statistics on
	    #	  v(i)
	    # * if spec['fieldname'] is 'absolute_rate', we compute the
	    #   statistics on
	    #	  v(i) / (t(i - 1) / t(i))
	    #
	    # The returned value is a struct with the same fields than the
	    # samples. Each element is a Stats object
	    def stats(samples, spec)
		return if samples.empty?
		type = samples.first.class
		spec = spec.inject(Hash.new) do |h, (k, v)|
		    spec[k.to_sym] = v.to_sym
		    spec
		end
		spec[:t]  = :exclude
		spec[:dt] = :absolute

		# Initialize the result value
		fields = type.members.
		    find_all { |n| spec[n.to_sym] != :exclude }.
		    map { |n| n.to_sym }
		result = Struct.new(*fields).new
		fields.each do |name|
		    result[name] = Stat.new(0, 0, 0, 0, nil)
		end

		# Compute the deltas if the mode is not absolute
		last_sample = nil
		samples = samples.map do |original_sample|
		    sample = original_sample.dup
		    fields.each do |name|
			next unless value = sample[name]
			unless spec[name] == :absolute || spec[name] == :absolute_rate
			    if last_sample && last_sample[name]
				sample[name] -= last_sample[name]
			    else
				sample[name] = nil
				next
			    end
			end
		    end
		    last_sample = original_sample
		    sample
		end

		# Compute the rates if needed
		samples = samples.map do |sample|
		    fields.each do |name|
			next unless value = sample[name]
			if spec[name] == :rate || spec[name] == :absolute_rate
			    if sample.dt
				sample[name] = value / sample.dt
			    else
				sample[name] = nil
				next
			    end
			end
		    end
		    sample
		end

		samples.each do |sample|
		    fields.each do |name|
			next unless value = sample[name]
			if !result[name].max || value > result[name].max
			    result[name].max = value
			end

			result[name].total += value
			result[name].count += 1
		    end
		    last_sample = sample
		end

		result.each do |r|
		    r.mean = Float(r.total) / r.count
		end

		samples.each do |sample|
		    fields.each do |name|
			next unless value = sample[name]
			result[name].stddev += (value - result[name].mean) ** 2
		    end
		end

		result.each do |r|
		    r.stddev = Math.sqrt(r.stddev / r.count)
		end
	    end
	end
	Roby::Control.at_cycle_end(&method(:check_event_assertions))
	Roby::Control.finalizers << method(:finalize_event_assertions)
	Roby::Control.finalizers << method(:interrupt_waiting_threads)

	module Assertions
	    # Wait for any event in +positive+ to happen. If +negative+ is
	    # non-empty, any event happening in this set will make the
	    # assertion fail. If events in +positive+ are task events, the
	    # :stop events of the corresponding tasks are added to negative
	    # automatically.
	    #
	    # If a block is given, it is called from within the control thread
	    # after the checks are in place
	    #
	    # So, to check that a task fails, do
	    #
	    #	assert_events(task.event(:fail)) do
	    #	    task.start!
	    #	end
	    #
	    def assert_any_event(positive, negative = [], msg = nil, &block)
		Roby.condition_variable(false) do |cv|
		    positive = Array[*positive].to_value_set
		    negative = Array[*negative].to_value_set
		    positive.each do |ev|
			if ev.respond_to?(:task)
			    stop = ev.task.event(:stop)
			    unless positive.include?(stop)
				negative << stop
			    end
			end
		    end

		    Roby::Control.synchronize do
			failing_events = nil
			unless failing_events = Test.assert_any_event_result(positive, negative)
			    this_thread = Thread.current

			    Test.event_assertions << [this_thread, cv, positive, negative]
			    Roby.once(&block) if block_given?
			    begin
				cv.wait(Roby::Control.mutex)
			    ensure
				Test.event_assertions.delete_if { |thread, *_| thread == this_thread }
			    end

			    failing_events = this_thread[ASSERT_ANY_EVENTS_TLS]
			end

			unless failing_events.empty?
			    flunk("events #{failing_events.join(", ")} happened in #{msg}")
			end
		    end
		end
	    end

	    # Starts +task+ and checks it succeeds
	    def assert_succeeds(task, msg = nil)
		assert_any_event([task.event(:success)], [], msg) do
		    plan.permanent(task)
		    task.start!
		end
	    end

	    # This assertion fails if the relative error between +found+ and
	    # +expected+is more than +error+
	    def assert_relative_error(expected, found, error, msg = "")
		if expected == 0
		    assert_in_delta(0, found, error, "comparing #{found} to #{expected} in #{msg}")
		else
		    assert_in_delta(0, (found - expected) / expected, error, "comparing #{found} to #{expected} in #{msg}")
		end
	    end

	    # This assertion fails if +found+ and +expected+ are more than +dl+
	    # meters apart in the x, y and z coordinates, or +dt+ radians apart
	    # in angles
	    def assert_same_position(expected, found, dl = 0.01, dt = 0.01, msg = "")
		assert_relative_error(expected.x, found.x, dl, msg)
		assert_relative_error(expected.y, found.y, dl, msg)
		assert_relative_error(expected.z, found.z, dl, msg)
		assert_relative_error(expected.yaw, found.yaw   , dt, msg)
		assert_relative_error(expected.pitch, found.pitch , dt, msg)
		assert_relative_error(expected.roll, found.roll  , dt, msg)
	    end
	end

	class ControlQuitError < RuntimeError; end
	class TestCase < Test::Unit::TestCase
	    include Roby::Test
	    include Assertions

	    def self.robot(name, kind = name)
		Roby.app.robot name, kind
		require 'roby/app/load'
	    end

	    def setup
		super
		Roby::Test.waiting_threads << Thread.current
	    end

	    def teardown
		Roby::Test.waiting_threads.delete(Thread.current)
		super
	    end

	    def run(result)
		Roby::Test.waiting_threads.clear

		Roby.app.simulation
		Roby.app.single
		Roby.app.setup
		Roby.app.run do
		    super
		end
	    end

	    def datasets_dir
		"#{APP_DIR}/test/datasets" 
	    end
	    def dataset_prefix
		"#{Roby.app.robot_name}-#{self.class.name.gsub('TC_', '').underscore}-#{@method_name.gsub('test_', '')}"
	    end

	    # Saves +file+, which is taken in the log directory, in the
	    # test/datasets directory.  The data set is saved as
	    # 'robot-testname-testmethod-suffix'
	    def save_dataset(file, suffix = '')
		unless File.directory?(datasets_dir)
		    FileUtils.mkdir_p(datasets_dir)
		end
		destname = "#{datasets_dir}/#{dataset_prefix}"
		destname << "-#{suffix}" unless suffix.empty?
		destname << File.extname(file)

		FileUtils.cp "#{Roby.app.log_dir}/#{file}", destname
	    end

	    def sampling(*args, &block); Test.sampling(*args, &block) end
	    def stats(*args, &block); Test.stats(*args, &block) end
	end
    end
end


