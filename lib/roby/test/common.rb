require 'test/unit'
require 'roby'
require 'utilrb/module/attr_predicate'

module Roby
    module Test
	include Roby
	Unit = ::Test::Unit

	attr_reader :timings
	class << self
	    attr_accessor :check_allocation_count
	end

	# The plan used by the tests
	def plan; Roby.plan end

	# Clear the plan and return it
	def new_plan
	    Roby.plan.clear
	    plan
	end

	# a [collection, collection_backup] array of the collections saved
	# by #original_collections
	attr_reader :original_collections

	# Saves the current state of +obj+. This state will be restored by
	# #restore_collections. +obj+ must respond to #<< to add new elements
	# (hashes do not work whild arrays or sets do)
	def save_collection(obj)
	    original_collections << [obj, obj.dup]
	end

	# Restors the collections saved by #save_collection to their previous state
	def restore_collections
	    original_collections.each do |col, backup|
		col.clear
		if col.kind_of?(Hash)
		    col.merge! backup
		else
		    backup.each(&col.method(:<<))
		end
	    end
	end

	def setup
	    @original_roby_logger_level = Roby.logger.level
	    @timings = { :start => Time.now }

	    @original_collections = []
	    Thread.abort_on_exception = true
	    @remote_processes = []

	    if Test.check_allocation_count
		GC.start
		GC.disable
	    end

	    if defined? Roby::Planning::Planner
		Roby::Planning::Planner.last_id = 0 
	    end

	    # Save and restore Control's global arrays
	    save_collection Roby::Control.event_processing
	    save_collection Roby::Control.structure_checks
	    save_collection Roby::Control.at_cycle_end_handlers
	    save_collection Roby::EventGenerator.event_gathering
	    Roby.control.instance_variable_set("@quit", 0)
	    Roby.control.abort_on_exception = true
	    Roby.control.abort_on_application_exception = true
	    Roby.control.abort_on_framework_exception = true

	    save_collection Roby::Propagation.event_ordering
	    save_collection Roby::Propagation.delayed_events

	    save_collection Roby.exception_handlers
	    timings[:setup] = Time.now
	end

	def teardown_plan
	    old_gc_roby_logger_level = Roby.logger.level
	    if debug_gc?
		Roby.logger.level = Logger::DEBUG
	    end

	    if Roby.control.thread
		# Control thread is running, quit it
		Roby.control.quit
		Roby.control.join
	    else
		catch(:done_cleanup) do
		    begin
			assert_doesnt_timeout(10) do
			    loop do
				Roby::Control.synchronize do
				    Roby.plan.garbage_collect
				    throw :done_cleanup unless Roby.control.clear
				end
				process_events
				sleep(0.1)
			    end
			end
		    rescue Test::Unit::AssertionFailedError
			Roby.warn "  timeout on plan cleanup. Remaining tasks are #{Roby.plan.known_tasks}"
		    rescue
			Roby.warn "  failed to properly cleanup the plan\n  #{$!.full_message}"
		    end
		end
	    end

	    plan.clear
	ensure
	    Roby.logger.level = old_gc_roby_logger_level
	end

	def teardown
	    timings[:quit] = Time.now
	    teardown_plan
	    timings[:teardown_plan] = Time.now

	    stop_remote_processes
	    if defined? DRb
		DRb.stop_service if DRb.thread
	    end

	    restore_collections

	    # Clear all relation graphs in TaskStructure and EventStructure
	    spaces = []
	    if defined? Roby::TaskStructure
		spaces << Roby::TaskStructure
	    end
	    if defined? Roby::EventStructure
		spaces << Roby::EventStructure
	    end
	    spaces.each do |space|
		space.relations.each do |rel| 
		    vertices = rel.enum_for(:each_vertex).to_a
		    unless vertices.empty?
			Roby.warn "  the following vertices are still present in #{rel}: #{vertices.to_a}"
			vertices.each { |v| v.clear_vertex }
		    end
		end
	    end

	    Roby::TaskStructure::Hierarchy.interesting_events.clear
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
		Roby.warn "#{count} -> #{remains} (#{count - remains})"
	    end
	    timings[:end] = Time.now

	    if display_timings?
		begin
		    display_timings!
		rescue
		    Roby.warn $!.full_message
		end
	    end

	ensure
	    Roby.logger.level = @original_roby_logger_level
	    self.console_logger = false
	end

	# Process pending events
	def process_events
	    Roby::Control.synchronize do
		Control.instance.process_events
	    end
	end

	# The list of children started using #remote_process
	attr_reader :remote_processes

	# Creates a set of tasks and returns them. Each task is given an unique
	# 'id' which allows to recognize it in a failed assertion.
	#
	# Known options are:
	# missions:: how many mission to create [0]
	# discover:: how many tasks should be discovered [0]
	# tasks:: how many tasks to create outside the plan [0]
	# model:: the task model [Roby::Task]
	# plan:: the plan to apply on [plan]
	#
	# The return value is [missions, discovered, tasks]
	#   (t1, t2), (t3, t4, t5), (t6, t7) = prepare_plan :missions => 2,
	#	:discover => 3, :tasks => 2
	#
	# An empty set is omitted
	#   (t1, t2), (t6, t7) = prepare_plan :missions => 2, :tasks => 2
	#
	# If a set is a singleton, the only object of this singleton is returned
	#   t1, (t6, t7) = prepare_plan :missions => 1, :tasks => 2
	#    
	def prepare_plan(options)
	    options = validate_options options,
		:missions => 0, :discover => 0, :tasks => 0,
		:permanent => 0,
		:model => Roby::Task, :plan => plan

	    missions, permanent, discovered, tasks = [], [], [], []
	    (1..options[:missions]).each do |i|
		options[:plan].insert(t = options[:model].new(:id => "mission-#{i}"))
		missions << t
	    end
	    (1..options[:permanent]).each do |i|
		options[:plan].permnanent(t = options[:model].new(:id => "perm-#{i}"))
		permanent << t
	    end
	    (1..options[:discover]).each do |i|
		options[:plan].discover(t = options[:model].new(:id => "discover-#{i}"))
		discovered << t
	    end
	    (1..options[:tasks]).each do |i|
		tasks << options[:model].new(:id => "task-#{i}")
	    end

	    result = []
	    [missions, permanent, discovered, tasks].each do |set|
		unless set.empty?
		    set = *set
		    result << set
		end
	    end
	    if result.size == 1 then result.first
	    else result
	    end
	end

	# Start a new process and saves its PID in #remote_processes. If a block is
	# given, it is called in the new child. #remote_process returns only after
	# this block has returned.
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

	# Stop all the remote processes that have been started using #remote_process
	def stop_remote_processes
	    remote_processes.reverse.each do |pid, quit_w|
		quit_w.write('OK') 
		Process.waitpid(pid)
	    end
	    remote_processes.clear
	end

	def finish_planning(task)
	    assert(planner = task.planning_task)
	    planner.start! if planner.pending?
	    planner.thread.join
	    Control.instance.process_events
	    assert(planner.success?)
	    planner.planned_task
	end


	# Exception raised in the block of assert_doesnt_timeout when the timeout
	# is reached
	class FailedTimeout < RuntimeError; end

	# Checks that the given block returns within +seconds+ seconds
	def assert_doesnt_timeout(seconds, message = "watchdog #{seconds} failed")
	    watched_thread = Thread.current
	    watchdog = Thread.new do
		sleep(seconds)
		watched_thread.raise FailedTimeout
	    end

	    assert_block(message) do
		begin
		    yield
		    true
		rescue FailedTimeout
		ensure
		    watchdog.kill
		    watchdog.join
		end
	    end
	end

	# Checks that the assertions in the block pass within +timeout+ seconds. If
	# +event+ is given, it is the message that is displayed if the assertion
	# fails
	def assert_happens(timeout = 5, event = "")
	    error = nil
	    assert_doesnt_timeout(timeout, "#{event} did not happen") do
		loop do
		    begin
			yield
			return
		    rescue Exception => e
			error = e
			process_events
			sleep(0.1)
		    end
		end
	    end

	rescue Test::Unit::AssertionFailedError
	    raise error, "failed to achieve #{event}: #{error.message}", error.backtrace
	end

	# Checks that +event+ is emitted within +timeout+ seconds
	def assert_event(event, timeout = 5)
	    assert_happens(timeout, "event #{event.symbol}") do
		assert(event.happened?)
	    end
	end

	def assert_marshallable(object)
	    begin
		Marshal.dump(object)
		true
	    rescue TypeError
	    end
	end

	# The console logger object. See #console_logger=
	attr_reader :console_logger

	attr_predicate :debug_gc?, true
	attr_predicate :display_timings?, true
	def display_timings!
	    timings = self.timings.sort_by { |_, t| t }
	    ref = timings[0].last

	    format, header, times = "", [], []
	    format << "%#{method_name.size}s"
	    header << method_name
	    times  << ""
	    timings.each do |name, time| 
		name = name.to_s
		time = "%.2f" % [time - ref]

		col_size = [name.size, time.size].max
		format << " % #{col_size}s"
		header << name
		times << time
	    end

	    puts
	    puts format % header
	    puts format % times
	end

	# Enable display of all plan events on the console
	def console_logger=(value)
	    if value
		require 'roby/log/console'
		@console_logger = Roby::Log::ConsoleLogger.new(STDERR)
		Roby::Log.add_logger << console_logger
	    elsif defined? Roby::Log
		Roby::Log.remove_logger console_logger
		@console_logger = nil
	    end
	end
    end
end

