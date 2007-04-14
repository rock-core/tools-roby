require 'active_support/core_ext/string/inflections'
class String # :nodoc: all
    include ActiveSupport::CoreExtensions::String::Inflections
end

require 'roby/test/common'
require 'roby/app'
require 'fileutils'

module Roby
    module Test
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
	    def assert_any_event(positive, negative = [], &block)
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
			    flunk("events #{failing_events.join(", ")} happened")
			end
		    end
		end
	    end

	    # Starts +task+ and checks it succeeds
	    def assert_succeeds(task)
		Roby::Control.synchronize do
		    plan.permanent(task)
		end

		assert_any_event(task.event(:success), task.event(:stop)) do
		    task.start!
		end
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
	end
    end
end


