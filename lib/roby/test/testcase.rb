require 'active_support/core_ext/string/inflections'
class String # :nodoc: all
    include ActiveSupport::CoreExtensions::String::Inflections
end

require 'roby/test/common'
require 'roby/app'
require 'roby/test/tools'
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
		if positive_ev = positive.find { |ev| ev.happened? }
		    return false, "#{positive_ev} happened"
		end
		failure = negative.find_all { |ev| ev.happened? }
		unless failure.empty?
		    return true, "#{failure} happened"
		end

		if positive.all? { |ev| ev.unreachable? }
		    return true, "all positive events are unreachable"
		end

		nil
	    end

	    # This method is inserted in the control thread to implement
	    # Assertions#assert_events
	    def check_event_assertions
		event_assertions.delete_if do |thread, cv, positive, negative|
		    error, result = assert_any_event_result(positive, negative)
		    if !error.nil?
			thread[ASSERT_ANY_EVENTS_TLS] = [error, result]
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

		    unreachability_reason = ValueSet.new
		    Roby::Control.synchronize do
			positive.each do |ev|
			    ev.if_unreachable(true) do |reason|
				unreachability_reason << reason if reason
			    end
			end

			error, result = Test.assert_any_event_result(positive, negative)
			if error.nil?
			    this_thread = Thread.current

			    Test.event_assertions << [this_thread, cv, positive, negative]
			    Roby.once(&block) if block_given?
			    begin
				cv.wait(Roby::Control.mutex)
			    ensure
				Test.event_assertions.delete_if { |thread, _| thread == this_thread }
			    end

			    error, result = this_thread[ASSERT_ANY_EVENTS_TLS]
			end

			if error
			    if !unreachability_reason.empty?
				flunk("#{msg} all positive events are unreachable for the following reason:\n  #{unreachability_reason.to_a.join("\n  ")}")
			    elsif msg
				flunk("#{msg} failed: #{result}")
			    else
				flunk(result)
			    end
			end
		    end
		end
	    end

	    # Starts +task+ and checks it succeeds
	    def assert_succeeds(task, *args)
		if !task.kind_of?(Roby::Task)
		    Roby.execute do
			plan.insert(task = planner.send(task, *args))
		    end
		end

		assert_any_event([task.event(:success)], [], nil) do
		    plan.permanent(task)
		    task.start! if task.pending?
		    yield if block_given?
		end
	    end

	    def control_priority
		old_priority = Thread.current.priority 
		Thread.current.priority = Roby.control.thread.priority

		yield
	    ensure
		Thread.current.priority = old_priority
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
		assert_relative_error(expected.yaw, found.yaw, dt, msg)
		assert_relative_error(expected.pitch, found.pitch, dt, msg)
		assert_relative_error(expected.roll, found.roll, dt, msg)
	    end
	end

	class ControlQuitError < RuntimeError; end
	class TestCase < Test::Unit::TestCase
	    include Roby::Test
	    include Assertions
	    class << self
		attribute(:case_config) { Hash.new }
		attribute(:methods_config) { Hash.new }
		attr_reader :app_setup
	    end

	    # Sets the robot configuration for this test case. If a block is
	    # given, it is called between the time the robot configuration is
	    # loaded and the time the test methods are started. It can
	    # therefore be used to change the robot configuration for the need
	    # of this particular test case
	    def self.robot(name, kind = name, &block)
		@app_setup = [name, kind, block]
	    end

	    def planner
		MainPlanner.new(plan)
	    end

	    def setup
		super
		Roby::Test.waiting_threads << Thread.current
	    end

	    def teardown
		Roby::Test.waiting_threads.delete(Thread.current)
		super
	    end

	    def method_config
		self.class.case_config.merge(self.class.methods_config[method_name] || Hash.new)
	    end

	    # Returns true if user interaction is to be disabled during this test
	    def automatic_testing?
		Roby.app.automatic_testing?
	    end

	    # Progress report for the curren test. Yields if user interaction is allowed
	    # and value is not zero
	    def progress(value)
		print "\r#{@method_name} progress: #{value}"
		STDOUT.flush
		if block_given? && !automatic_testing? && value > 0
		    yield
		end
	    end

	    def user_interaction
		return unless automatic_testing?

		test_result = catch(:validation_result) do
		    yield 
		    return
		end
		if test_result
		    flunk(*test_result)
		end
	    end

	    def user_validation(msg)
		return if automatic_testing?

		assert_block(msg) do
		    STDOUT.puts "Now validating #{msg}"
		    yield

		    STDIN.ask("\rIs the result OK ? [N,y]", false)
		end
	    end

	    # Do not run +test_name+ inside a simulation environment
	    # +test_name+ is the name of the method without +test_+. For
	    # instance:
	    #   nosim :init
	    #   def test_init
	    #   end
	    #
	    # See also TestCase.sim
	    def self.nosim(*names)
		names.each do |test_name|
		    config = (methods_config[test_name.to_s] ||= Hash.new)
		    config[:mode] = :nosim
		end
	    end

	    # Run +test_name+ only inside a simulation environment
	    # +test_name+ is the name of the method without +test_+. For
	    # instance:
	    #   nosim :init
	    #   def test_init
	    #   end
	    #
	    # See also TestCase.nosim
	    def self.sim(*names)
		names.each do |test_name|
		    config = (methods_config[test_name.to_s] ||= Hash.new)
		    config[:mode] = :sim
		end
	    end

	    def self.suite
		method_names = public_instance_methods(true)
		tests = method_names.delete_if {|method_name| method_name !~ /^(dataset|test)./}
		suite = Test::Unit::TestSuite.new(name)
		tests.sort.each do |test|
		    catch(:invalid_test) do
			suite << new(test)
		    end
		end
		if (suite.empty?)
		    catch(:invalid_test) do
			suite << new("default_test")
		    end
		end
		return suite
	    end

	    def run(result)
		Roby::Test.waiting_threads.clear

		name, kind, block = self.class.app_setup
		# Silently ignore the test suites which use a different robot
		if Roby.app.robot_name && 
		    (Roby.app.robot_name != name || Roby.app.robot_type != kind)
		    return
		end
		Roby.app.reset
		Roby.app.robot name, kind
		require 'roby/app/load'
		Roby.app.single
		Roby.app.setup
		if block
		    block.call
		end

		Roby.app.control.delete('executive')

		yield if block_given?

		case method_config[:mode]
		when :nosim
		    return if Roby.app.simulation?
		when :sim
		    return unless Roby.app.simulation?
		end

		@failed_test = false
		Roby.app.run do
		    super
		end

		keep_logdir = @failed_test || Roby.app.testing_keep_logs?
		save_logdir = (@failed_test && automatic_testing?) ||  Roby.app.testing_keep_logs?
		if save_logdir
		    subdir = @failed_test ? 'failures' : 'results'
		    dirname = Roby::Application.unique_dirname(File.join(APP_DIR, 'test', subdir), dataset_prefix)
		    FileUtils.mv Roby.app.log_dir, dirname
		end
		if !keep_logdir
		    FileUtils.rm_rf Roby.app.log_dir
		end

	    rescue Exception
		puts "testcase #{method_name} teardown failed with\n#{$!.full_message}"
	    end

	    def add_error(*args, &block)
		@failed_test = true
		super
	    end
	    def add_failure(*args, &block)
		@failed_test = true
		super
	    end

	    def datasets_dir
		"#{APP_DIR}/test/datasets" 
	    end
	    def dataset_prefix
		"#{Roby.app.robot_name}-#{self.class.name.gsub('TC_', '').underscore}-#{@method_name.gsub(/(?:test|dataset)_/, '')}"
	    end
	    def dataset_file_path(dataset_name, file)
		path = File.join(datasets_dir, dataset_name, file)
		if !File.file?(path)
		    raise "#{path} does not exist"
		end

		path
	    rescue
		flunk("dataset #{dataset_name} has not been generated: #{$!.message}")
	    end

	    # Saves +file+, which is taken in the log directory, in the
	    # test/datasets directory.  The data set is saved as
	    # 'robot-testname-testmethod-suffix'
	    def save_dataset(files = nil, suffix = '')
		destname = dataset_prefix
		destname << "-#{suffix}" unless suffix.empty?

		dir = File.join(datasets_dir, destname)
		if File.exists?(dir)
		    relative_dir = dir.gsub(/^#{Regexp.quote(APP_DIR)}/, '')
		    unless STDIN.ask("\r#{relative_dir} already exists. Delete ? [N,y]", false)
			raise "user abort"
		    end
		    FileUtils.rm_rf dir
		end
		FileUtils.mkdir_p(dir)

		files ||= Dir.entries(Roby.app.log_dir).find_all do |path|
		    File.file? File.join(Roby.app.log_dir, path)
		end

		[*files].each do |path|
		    FileUtils.mv "#{Roby.app.log_dir}/#{path}", dir
		end
	    end

	    def sampling(*args, &block); Test.sampling(*args, &block) end
	    def stats(*args, &block); Test.stats(*args, &block) end
	end
    end
end


