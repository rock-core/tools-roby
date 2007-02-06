require 'test/unit'
require 'roby'

module Roby
    module Test
	include Roby
	class << self
	    attr_accessor :check_allocation_count
	end

	attr_reader :original_collections
	def save_collection(obj)
	    original_collections << [obj, obj.dup]
	end
	def restore_collections
	    original_collections.each do |col, backup|
		col.clear
		backup.each(&col.method(:<<))
	    end
	end

	def setup
	    @original_collections = []
	    Thread.abort_on_exception = true
	    @remote_processes = []

	    if Test.check_allocation_count
		GC.start
		GC.disable
	    end

	    # Save and restore Control's global arrays
	    if defined? Roby::Control
		save_collection Roby::Control.event_processing
		save_collection Roby::Control.structure_checks
		Roby::Control.instance.abort_on_exception = true
		Roby::Control.instance.abort_on_application_exception = true
		Roby::Control.instance.abort_on_framework_exception = true
	    end

	    if defined? Roby.exception_handlers
		save_collection Roby.exception_handlers
	    end
	end

	def teardown
	    stop_remote_processes
	    if defined? DRb
		DRb.stop_service if DRb.thread
	    end

	    restore_collections
	    if respond_to?(:plan) && plan
		plan.clear
	    end

	    # Clear all relation graphs in TaskStructure and EventStructure
	    spaces = []
	    if defined? Roby::TaskStructure
		spaces << Roby::TaskStructure
	    end
	    if defined? Roby::EventStructure
		spaces << Roby::EventStructure
	    end
	    spaces.each do |space|
		space.relations.each { |rel| rel.each_vertex { |v| v.clear_vertex } }
	    end

	    if defined? Roby::Control
		Roby::Control.instance.abort_on_exception = false
		Roby::Control.instance.abort_on_application_exception = false
		Roby::Control.instance.abort_on_framework_exception = false
	    end

	    if Test.check_allocation_count
		require 'utilrb/objectstats'
		count = ObjectStats.count
		GC.start
		remains = ObjectStats.count
		STDERR.puts "#{count} -> #{remains} (#{count - remains})"
	    end
	end

	attr_reader :remote_processes
	def remote_process
	    start_r, start_w= IO.pipe
	    quit_r, quit_w = IO.pipe
	    remote_pid = fork do
		start_r.close
		yield
		start_w.write('OK')
		quit_r.read(2)
	    end
	    start_w.close
	    start_r.read(2)

	    remote_processes << [remote_pid, quit_w]
	    remote_pid

	ensure
	    start_r.close
	end
	
	def stop_remote_processes
	    remote_processes.each do |pid, quit_w|
		quit_w.write('OK') 
		Process.waitpid(pid)
	    end
	    remote_processes.clear
	end

	def finish_planning(task)
	    assert(planner = task.planning_task)
	    planner.start! if planner.pending?
	    planner.thread.join
	    STDERR.puts planner.planned_task
	    Control.instance.process_events
	    assert(planner.success?)
	    planner.planned_task
	end
	    

	#require 'roby/log/console'
	#Roby::Log.loggers << Roby::Log::ConsoleLogger.new(STDERR)
	#Roby.logger.level = Logger::DEBUG
	#Test.check_allocation_count = true

	class FailedTimeout < RuntimeError; end
	def assert_doesnt_timeout(seconds, message = "watchdog #{seconds} failed")
	    watched_thread = Thread.current
	    watchdog = Thread.new do
		sleep(seconds)
		watched_thread.raise FailedTimeout
	    end

	    assert_block(message) do
		begin
		    yield
		    watchdog.kill
		    true
		rescue FailedTimeout
		end
	    end
	end

	def assert_event(event, timeout = 5)
	    assert_doesnt_timeout(timeout, "event #{event.symbol} never happened") do
		while !event.happened?
		    Roby::Control.instance.process_events({}, false)
		    sleep(0.1)
		end
	    end
	end

	def assert_marshallable(object)
	    begin
		Marshal.dump(object)
		true
	    rescue TypeError
	    end
	end

	def assert_drbobject_of(object, drb_object)
	    assert_drbset_of([object], [drb_object])
	end
	def assert_drbset_of(objects, drb_objects)
	    unwrapped_objects = []
	    # DO NOT call #map. drb_objects is a remote object
	    # itself, so #map would not work as expected
	    #
	    # THIS IS NOT a Ruby bug. It only happens because
	    # we have here a special case where a local object
	    # is not unwrapped. It is a case not covered by
	    # DRb
	    drb_objects.each do |drb_obj| 
		assert_kind_of(DRb::DRbObject, drb_obj)
		unwrapped_objects << DRb.to_obj(drb_obj.__drbref)
	    end

	    assert_equal(objects.to_set, unwrapped_objects.to_set)
	end

	def assert_droby_object_of(object, drb_object)
	    assert_droby_set_of([object], [drb_object])
	end
	def assert_droby_set_of(objects, drb_objects)
	    remote_objects = []
	    drb_objects.each do |obj|
		assert_kind_of(Roby::Distributed::MarshalledObject, obj)
		remote_objects << obj.remote_object
	    end
	    assert_drbset_of(objects, remote_objects)
	end
    end
end


