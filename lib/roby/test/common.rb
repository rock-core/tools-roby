require 'minitest/spec'
require 'flexmock/minitest'

# simplecov must be loaded FIRST. Only the files required after it gets loaded
# will be profiled !!!
if ENV['TEST_ENABLE_COVERAGE'] == '1'
    begin
        require 'simplecov'
    rescue LoadError
        require 'roby'
        Roby.warn "coverage is disabled because the 'simplecov' gem cannot be loaded"
    rescue Exception => e
        require 'roby'
        Roby.warn "coverage is disabled: #{e.message}"
    end
end

if ENV['TEST_ENABLE_PRY'] != '0'
    begin
        require 'pry'
    rescue Exception
        require 'roby'
        Roby.warn "debugging is disabled because the 'pry' gem cannot be loaded"
    end
end

require 'roby'

require 'roby/test/assertion'
require 'roby/test/error'
require 'roby/test/teardown_plans'

module Roby
    # This module is defining common support for tests that need the Roby
    # infrastructure
    #
    # It assumes that the tests are started using roby's test command. Tests
    # using this module can NOT be started with only e.g. testrb.
    #
    # @see SelfTest
    module Test
	include Roby
        include TeardownPlans

        extend Logger::Hierarchy
        extend Logger::Forward

	BASE_PORT     = 1245
	DISCOVERY_SERVER = "druby://localhost:#{BASE_PORT}"
	REMOTE_PORT    = BASE_PORT + 1
	LOCAL_PORT     = BASE_PORT + 2
	REMOTE_SERVER  = "druby://localhost:#{BASE_PORT + 3}"
	LOCAL_SERVER   = "druby://localhost:#{BASE_PORT + 4}"

	class << self
	    attr_accessor :check_allocation_count
	end

	# The plan used by the tests
        attr_reader :plan
        # The decision control component used by the tests
        attr_reader :control
        def engine; plan.engine if plan end

        attr_reader :connection_spaces

        def execute(&block)
            engine.execute(&block)
        end

	# Clear the plan and return it
	def new_plan
	    plan.clear
	    plan
	end

        def create_transaction
            t = Roby::Transaction.new(plan)
            @transactions << t
            t
        end

        def deprecated_feature
            Roby.enable_deprecation_warnings = false
            yield
        ensure
            Roby.enable_deprecation_warnings = true
        end

        def create_connection_space(port, plan: nil)
            if !plan
                register_plan(plan = Plan.new)
            end
            if !plan.execution_engine
                ExecutionEngine.new(plan)
            end
            space = Distributed::ConnectionSpace.new(plan: plan, listen_at: port)
            register_connection_space(space)
            space
        end

        def register_connection_space(space)
            @connection_spaces << space
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
                    backup.each do |obj|
                        col << obj
                    end
		end
	    end
            original_collections.clear
	end

	def setup
            Roby.app.reload_config
            @log_levels = Hash.new
            @connection_spaces = Array.new
            @transactions = Array.new

            if !@plan
                @plan = Roby.plan
            end
            register_plan(@plan)

            super if defined? super

	    @console_logger ||= false
            @event_logger   ||= false

	    @original_roby_logger_level = Roby.logger.level

	    @original_collections = []
	    Thread.abort_on_exception = false
	    @remote_processes = []

            Roby.app.log_setup 'robot', 'DEBUG:robot.txt'
            Roby.app.log_server = false

	    if Test.check_allocation_count
		GC.start
		GC.disable
	    end

	    unless DRb.primary_server
                @started_drb = true
		DRb.start_service 'druby://localhost:0'
	    end

            plan.engine.gc_warning = false

            @handler_ids = Array.new
            @handler_ids << engine.add_propagation_handler(:type => :external_events) do |plan|
                Test.verify_watched_events
            end
	end

        def assert_adds_roby_localized_error(matcher)
            matcher = matcher.match
            errors = plan.execution_engine.gather_errors do
                yield
            end

            errors = errors.map(&:exception)
            assert !errors.empty?, "expected to have added a LocalizedError, but got none"
            errors.each do |e|
                assert_exception_can_be_pretty_printed(e)
            end
            if matched_e = errors.find { |e| matcher === e }
                return matched_e
            elsif errors.empty?
                flunk "block was expected to add an error matching #{matcher}, but did not"
            else
                raise SynchronousEventProcessingMultipleErrors.new(errors)
            end
        end

        def assert_exception_can_be_pretty_printed(e)
            PP.pp(e, "") # verify that the exception can be pretty-printed, all Roby exceptions should
        end

        def inhibit_fatal_messages(&block)
            with_log_level(Roby, Logger::FATAL, &block)
        end

        def set_log_level(log_object, level)
            if log_object.respond_to?(:logger)
                log_object = log_object.logger
            end
            @log_levels[log_object] ||= log_object.level
            log_object.level = level
        end

        def reset_log_levels
            @log_levels.each do |log_object, level|
                log_object.level = level
            end
            @log_levels.clear
        end

        def with_log_level(log_object, level)
            if log_object.respond_to?(:logger)
                log_object = log_object.logger
            end
            current_level = log_object.level
            log_object.level = level

            yield

        ensure
            if current_level
                log_object.level = current_level
            end
        end

	def teardown
            @transactions.each do |trsc|
                if !trsc.finalized?
                    trsc.discard_transaction
                end
            end
            teardown_registered_plans

            if @handler_ids && engine
                @handler_ids.each do |handler_id|
                    engine.remove_propagation_handler(handler_id)
                end
            end
            Test.verify_watched_events

            # Plan teardown would have disconnected the peers already
            connection_spaces.each do |space|
                space.close
            end
	    stop_remote_processes
            if DRb.thread && @started_drb
                DRb.stop_service
            end

	    restore_collections

            clear_relation_spaces

	    if defined? Roby::Application
		Roby.app.abort_on_exception = false
		Roby.app.abort_on_application_exception = false
	    end

	    if defined? Roby::Log
		Roby::Log.known_objects.clear
	    end

	    if Test.check_allocation_count
		require 'utilrb/objectstats'
		count = ObjectStats.count
		GC.start
		remains = ObjectStats.count
		Roby.warn "#{count} -> #{remains} (#{count - remains})"
	    end

            super if defined? super

	ensure
            reset_log_levels
            clear_registered_plans

            if @original_roby_logger_level
                Roby.logger.level = @original_roby_logger_level
            end
            self.console_logger = false
            self.event_logger   = false
	end
        
        def clear_relation_spaces
	    # Clear all relation graphs in TaskStructure and EventStructure
	    [TaskStructure, EventStructure].each do |space|
		space.relations.each do |rel| 
		    vertices = rel.enum_for(:each_vertex).to_a
		    if !vertices.empty?
			Roby.warn "  the following vertices are still present in #{rel}: #{vertices.to_a}"
			vertices.each { |v| v.clear_vertex }
		    end
                    if rel.respond_to?(:task_graph) && !rel.task_graph.empty?
			Roby.warn "  the task graph for #{rel} is not empty while its corresponding relation graph is"
			rel.task_graph.clear
                    end
		end
	    end

	    TaskStructure::Dependency.interesting_events.clear
        end

	# Process pending events
	def process_events
            registered_plans.each do |p|
                engine = p.execution_engine

                engine.join_all_worker_threads
                if !engine.running?
                    engine.start_new_cycle
                    engine.process_events
                    engine.cycle_end(Hash.new)
                else
                    engine.wait_one_cycle
                end
            end
	end

        def process_events_until(timeout = 5)
            start = Time.now
            while !yield
                process_events
                Thread.pass
                if Time.now - start > timeout
                    flunk("failed to reach expected condition")
                end
            end
        end

        # Use to call the original method on a partial mock
        def flexmock_call_original(object, method, *args, &block)
            Test.warn "#flexmock_call_original is deprecated, use #flexmock_invoke_original instead"
            flexmock_invoke_original(object, method, *args, &block)
        end

        # Use to call the original method on a partial mock
        def flexmock_invoke_original(object, method, *args, &block)
            object.instance_variable_get(:@flexmock_proxy).proxy.flexmock_invoke_original(method, args, &block)
        end

	# The list of children started using #remote_process
	attr_reader :remote_processes

        def gather_log_messages(*message_names)
            message_names = message_names.map(&:to_s)
            logger_class = Class.new do
                attr_reader :messages
                def initialize
                    @messages = Array.new
                end

                message_names.each do |name|
                    define_method(name) do |time, args|
                        messages << [name, time, args]
                    end
                end

                def splat?; false end
                define_method(:logs_message?) do |m|
                    message_names.include?(m.to_s)
                end
                def close; end
            end

            logger = logger_class.new
            Log.add_logger(logger)

            yield

            Log.flush
            Log.remove_logger(logger)

            # Data formatted for logging should be directly marshallable. Verify
            # that.
            Marshal.dump(logger.messages)

            logger.messages
        end

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
		:missions => 0, :add => 0, :discover => 0, :tasks => 0,
		:permanent => 0,
		:model => Roby::Task, :plan => plan

	    missions, permanent, added, tasks = [], [], [], []
	    (1..options[:missions]).each do |i|
		options[:plan].add_mission(t = options[:model].new(:id => "mission-#{i}"))
		missions << t
	    end
	    (1..options[:permanent]).each do |i|
		options[:plan].add_permanent(t = options[:model].new(:id => "perm-#{i}"))
		permanent << t
	    end
	    (1..(options[:discover] + options[:add])).each do |i|
		options[:plan].add(t = options[:model].new(:id => "discover-#{i}"))
		added << t
	    end
	    (1..options[:tasks]).each do |i|
		tasks << options[:model].new(:id => "task-#{i}")
	    end

	    result = []
	    [missions, permanent, added, tasks].each do |set|
		unless set.empty?
		    result << set
		end
	    end

            result = result.map do |set|
                if set.size == 1 then set.first
                else set
                end
            end

            if result.size == 1
                return result.first
            end
            return *result
	end

	# Start a new process and saves its PID in #remote_processes. If a block is
	# given, it is called in the new child. #remote_process returns only after
	# this block has returned.
	def remote_process
	    start_r, start_w= IO.pipe
	    quit_r, quit_w = IO.pipe
	    remote_pid = fork do
                begin
                    start_r.close
                    yield
                rescue Exception => e
                    puts e.full_message
                end

                start_w.write('OK')
                quit_r.read(2)
	    end
	    start_w.close
	    result = start_r.read(2)

	    remote_processes << [remote_pid, quit_w]
	    remote_pid

	ensure
	    # start_r.close
	end

	# Stop all the remote processes that have been started using #remote_process
	def stop_remote_processes
	    remote_processes.reverse.each do |pid, quit_w|
		begin
		    quit_w.write('OK') 
		rescue Errno::EPIPE
		end
		begin
		    Process.waitpid(pid)
		rescue Errno::ECHILD
		end
	    end
	    remote_processes.clear
	end

	# Exception raised in the block of assert_doesnt_timeout when the timeout
	# is reached
	class FailedTimeout < RuntimeError; end

	def assert_original_error(klass, localized_error_type = LocalizedError)
	    old_level = Roby.logger.level
	    Roby.logger.level = Logger::FATAL

            begin
                yield
            rescue Exception => e
                assert_kind_of(localized_error_type, e)
                assert_respond_to(e, :error)
                assert_kind_of(klass, e.error)
            end
	ensure
	    Roby.logger.level = old_level
	end

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

	def verify_is_droby_marshallable_object(object)
            droby = object.droby_dump(nil)
	    marshalled = Marshal.dump(droby)
            droby = Marshal.load(marshalled)
            droby.proxy(Roby::Distributed::DumbManager)
	end

	# The console logger object. See #console_logger=
	attr_reader :console_logger

	attr_predicate :debug_gc?, true

	# Enable display of all plan events on the console
	def console_logger=(value)
	    if value && !@console_logger
		require 'roby/log/console'
		@console_logger = Roby::Log::ConsoleLogger.new(STDERR)
		Roby::Log.add_logger console_logger
	    elsif @console_logger
		Roby::Log.remove_logger console_logger
		@console_logger = nil
	    end
	end

        attr_reader :event_logger
        def event_logger=(value)
            if value && !@event_logger
		require 'roby/log/file'
		logfile = @method_name + ".log"
		logger  = Roby::Log::FileLogger.new(logfile)
		logger.stats_mode = false
		Roby::Log.add_logger logger
                @event_logger = logger
            elsif !value && @event_logger
                Roby::Log.remove_logger @event_logger
                @event_logger = nil
            end
        end

	def wait_thread_stopped(thread)
	    while !thread.stop?
		sleep(0.1)
		raise "#{thread} died" unless thread.alive?
	    end
	end

	def display_event_structure(object, relation, indent = "  ")
	    result   = object.to_s
	    object.history.each do |event|
		result << "#{indent}#{event.time.to_hms} #{event}"
	    end
	    children = object.child_objects(relation)
	    unless children.empty?
		result << " ->\n" << indent
		children.each do |child|
		    result << display_event_structure(child, relation, indent + "  ")
		end
	    end

	    result
	end

	@watched_events = []
	@waiting_threads  = []

	EVENT_WATCH_TLS = :test_watched_events

        class << self
            # A [thread, cv, positive, negative] list of event assertions
            attr_reader :watched_events
        end

        # Tests for events in +positive+ and +negative+ and returns
        # the set of failing events if the assertion has finished.
        # If the set is empty, it means that the assertion finished
        # successfully
        def self.event_watch_result(positive, negative, deadline = nil)
            if deadline && deadline < Time.now
                return true, "timed out waiting for #{positive.map(&:to_s).join(", ")} to happen"
            end

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
        def self.verify_watched_events
            watched_events.delete_if do |result_queue, positive, negative, deadline|
                error, result = Test.event_watch_result(positive, negative, deadline)
                if !error.nil?
                    result_queue.push([error, result])
                    true
                end
            end
        end

	module Assertions
	    # Wait for events to be emitted, or for some events to not be
            # emitted
            #
            # It will fail if all waited-for events become unreachable
            #
            # If a block is given, it is called after the checks are put in
            # place. This is required if the code in the block causes the
            # positive/negative events to be emitted
	    #
	    # @example test a task failure
	    #	assert_event_emission(task.fail_event) do
	    #	    task.start!
	    #	end
            #
            # @param [Array<EventGenerator>] positive the set of events whose
            #   emission we are waiting for
            # @param [Array<EventGenerator>] negative the set of events whose
            #   emission will cause the assertion to fail
            # @param [String] msg assertion failure message
            # @param [Float] timeout timeout in seconds after which the
            #   assertion fails if none of the positive events got emitted
            def assert_event_emission(positive = [], negative = [], msg = nil, timeout = 5, &block)
                error, result, unreachability_reason = watch_events(positive, negative, timeout, &block)

                if error
                    if !unreachability_reason.empty?
                        msg = format_unreachability_message(unreachability_reason)
                        flunk("all positive events are unreachable for the following reason:\n  #{msg}")
                    elsif msg
                        flunk("#{msg} failed: #{result}")
                    else
                        flunk(result)
                    end
                end
            end
            def watch_events(positive, negative, timeout, &block)
                positive = Array[*(positive || [])].to_set
                negative = Array[*(negative || [])].to_set
                if positive.empty? && negative.empty? && !block
                    raise ArgumentError, "neither a block nor a set of positive or negative events have been given"
                end

		control_priority do
                    engine.waiting_threads << Thread.current

                    unreachability_reason = Set.new
                    result_queue = Queue.new

                    engine.execute do
                        if positive.empty? && negative.empty?
                            positive, negative = yield
                            positive = Array[*(positive || [])].to_set
                            negative = Array[*(negative || [])].to_set
                            if positive.empty? && negative.empty?
                                raise ArgumentError, "#{block} returned no events to watch"
                            end
                        elsif block_given?
                            yield
                        end

                        error, result = Test.event_watch_result(positive, negative)
                        if !error.nil?
                            result_queue.push([error, result])
                        else
                            positive.each do |ev|
                                ev.if_unreachable(true) do |reason, event|
                                    unreachability_reason << [event, reason]
                                end
                            end
                            Test.watched_events << [result_queue, positive, negative, Time.now + timeout]
                        end
                    end

                    begin
                        if engine.running?
                            error, result = result_queue.pop
                        else
                            while result_queue.empty?
                                process_events
                                sleep(0.05)
                            end
                            error, result = result_queue.pop
                        end
                    ensure
                        Test.watched_events.delete_if { |_, q, _| q == result_queue }
                    end
                    return error, result, unreachability_reason
		end
            ensure
                engine.waiting_threads.delete(Thread.current)
            end

            def format_unreachability_message(unreachability_reason)
                msg = unreachability_reason.map do |ev, reason|
                    if reason.kind_of?(Exception)
                        Roby.format_exception(reason).join("\n")
                    elsif reason.respond_to?(:context)
                        context = if reason.context
                                      Roby.format_exception(reason.context).join("\n")
                                  end
                        "the emission of #{reason}#{context}"
                    end
                end
                msg.join("\n  ")
            end

            # Asserts that the given task is going to be added to the quarantine
            def assert_task_quarantined(task, timeout: 5)
                yield
                while !task.plan.quarantined_task?(task) && (Time.now - start) < timeout
                    task.plan.execution_engine.process_events
                end
            end

            # @deprecated use #assert_event_emission instead
	    def assert_any_event(positive = [], negative = [], msg = nil, timeout = 5, &block)
                Roby.warn_deprecated "#assert_any_event is deprecated, use #assert_event_emission instead"
                assert_event_emission(positive, negative, msg, timeout, &block)
	    end

            # @deprecated use #assert_event_becomes_unreachable instead
            def assert_becomes_unreachable(*args, &block)
                Roby.warn_deprecated "#assert_becomes_unreachable is deprecated, use #assert_event_becomes_unreachable instead"
                assert_event_becomes_unreachable(*args, &block)
            end

            # Verifies that the provided event becomes unreachable within a
            # certain time frame
            #
            # @param [EventGenerator] event
            # @param [Float] timeout in seconds
            # @yield a block of code that performs the action that should turn
            #   the event into unreachable
            def assert_event_becomes_unreachable(event, timeout = 5, &block)
                old_level = Roby.logger.level
                Roby.logger.level = Logger::FATAL
                error, message, unreachability_reason = watch_events(event, [], timeout, &block)
                if error = unreachability_reason.find { |ev, _| ev == event }
                    return
                end
                if !error
                    flunk("event has been emitted")
                else
                    msg = if !unreachability_reason.empty?
                              format_unreachability_message(unreachability_reason)
                          else
                              message
                          end
                    flunk("the following error happened before #{event} became unreachable:\n #{msg}")
                end
            ensure
                Roby.logger.level = old_level
            end

	    # Starts +task+ and checks it succeeds
	    def assert_succeeds(task, *args)
		control_priority do
		    if !task.kind_of?(Roby::Task)
			engine.execute do
			    plan.add_mission(task = planner.send(task, *args))
			end
		    end

		    assert_event_emission([task.event(:success)], [], nil) do
			plan.add_permanent(task)
			task.start! if task.pending?
			yield if block_given?
		    end
		end
	    end

	    def control_priority
                if !engine.thread
                    return yield
                end

		old_priority = Thread.current.priority 
		Thread.current.priority = engine.thread.priority + 1

		yield
	    ensure
		Thread.current.priority = old_priority if old_priority
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

        def develop_planning_method(method_name, args = Hash.new)
            options, args = Kernel.filter_options args,
                :planner_model => MainPlanner

            planner = options[:planner_model].new(plan)
            planner.send(method_name, args)
        rescue Roby::Planning::NotFound => e
            Roby.log_exception_with_backtrace(e, Roby, :fatal)
            raise
        end

        module ClassExtension
            attr_reader :planning_method_tests

            def test_planning_method(method_name, args = Hash.new)
                @planning_method_tests ||= Hash.new { |h, k| h[k] = Array.new }
                @planning_method_tests[method_name.to_sym] << args

                if !instance_method?("test_planning_method_#{method_name}")
                    define_method("test_planning_method_#{method_name}") do
                        tests = self.class.planning_method_tests[method_name.to_sym]
                        tests.each do |t|
                            develop_planning_method(method_name, t)
                        end
                    end
                end
            end
        end
    end
end

