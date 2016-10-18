require 'minitest/spec'
require 'roby/test/assertions'
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

FlexMock.partials_are_based = true

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

	BASE_PORT     = 21000
	DISCOVERY_SERVER = "druby://localhost:#{BASE_PORT}"
	REMOTE_PORT    = BASE_PORT + 1
	LOCAL_PORT     = BASE_PORT + 2
	REMOTE_SERVER  = "druby://localhost:#{BASE_PORT + 3}"
	LOCAL_SERVER   = "druby://localhost:#{BASE_PORT + 4}"

	# The plan used by the tests
        attr_reader :plan
        # The decision control component used by the tests
        attr_reader :control
        def execution_engine; plan.execution_engine if plan && plan.executable? end

        def execute(&block)
            execution_engine.execute(&block)
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
            flexmock(Roby).should_receive(:warn_deprecated).at_least.once
            yield
        ensure
            Roby.enable_deprecation_warnings = true
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
            @transactions = Array.new

            if !@plan
                @plan = Roby.plan
            end
            register_plan(@plan)

            super

	    @console_logger ||= false
            @event_logger   ||= false

	    @original_roby_logger_level = Roby.logger.level

	    @original_collections = []
	    Thread.abort_on_exception = false
	    @remote_processes = []

            Roby.app.log_server = false

            plan.execution_engine.gc_warning = false

            @watched_events = nil
            @handler_ids = Array.new
            @handler_ids << execution_engine.add_propagation_handler(description: 'Test.verify_watched_events', type: :external_events) do |plan|
                verify_watched_events
            end
	end

        def assert_adds_roby_localized_error(matcher)
            matcher = matcher.match.to_execution_exception_matcher
            errors = plan.execution_engine.gather_errors do
                yield
            end

            assert !errors.empty?, "expected to have added a LocalizedError, but got none"
            errors.each do |e|
                assert_exception_can_be_pretty_printed(e.exception)
            end
            if matched_e = errors.find { |e| matcher === e }
                return matched_e.exception
            elsif errors.empty?
                flunk "block was expected to add an error matching #{matcher}, but did not"
            else
                raise SynchronousEventProcessingMultipleErrors.new(errors.map(&:exception))
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

            if @handler_ids && execution_engine
                @handler_ids.each do |handler_id|
                    execution_engine.remove_propagation_handler(handler_id)
                end
            end
            verify_watched_events

            # Plan teardown would have disconnected the peers already
	    stop_remote_processes

	    restore_collections

	    if defined? Roby::Application
		Roby.app.abort_on_exception = false
		Roby.app.abort_on_application_exception = true
	    end

            super

	ensure
            reset_log_levels
            clear_registered_plans

            if @original_roby_logger_level
                Roby.logger.level = @original_roby_logger_level
            end
	end
        
	# Process pending events
	def process_events(timeout: 2, enable_scheduler: nil, join_all_waiting_work: true, raise_errors: true, garbage_collect_pass: true)
            exceptions = Array.new
            registered_plans.each do |p|
                engine = p.execution_engine

                first_pass = true
                while first_pass || (engine.has_waiting_work? && join_all_waiting_work)
                    first_pass = false

                    if join_all_waiting_work
                        engine.join_all_waiting_work(timeout: timeout)
                    end
                    engine.start_new_cycle
                    errors =
                        begin
                            current_scheduler_state = engine.scheduler.enabled?
                            if !enable_scheduler.nil?
                                engine.scheduler.enabled = enable_scheduler
                            end
                            engine.process_events(garbage_collect_pass: garbage_collect_pass)
                        ensure
                            engine.scheduler.enabled = current_scheduler_state
                        end

                    exceptions.concat(errors.exceptions)
                    engine.cycle_end(Hash.new)
                end
            end

            if raise_errors && !exceptions.empty?
                if exceptions.size == 1
                    e = exceptions.first
                    raise e.exception
                else
                    raise SynchronousEventProcessingMultipleErrors.new(exceptions.map(&:exception))
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
	#   (t1, t2), (t3, t4, t5), (t6, t7) = prepare_plan missions: 2,
	#	discover: 3, tasks: 2
	#
	# An empty set is omitted
	#   (t1, t2), (t6, t7) = prepare_plan missions: 2, tasks: 2
	#
	# If a set is a singleton, the only object of this singleton is returned
	#   t1, (t6, t7) = prepare_plan missions: 1, tasks: 2
	#    
	def prepare_plan(options)
	    options = validate_options options,
		missions: 0, add: 0, discover: 0, tasks: 0,
		permanent: 0,
		model: Roby::Task, plan: plan

	    missions, permanent, added, tasks = [], [], [], []
	    (1..options[:missions]).each do |i|
		options[:plan].add_mission_task(t = options[:model].new(id: "mission-#{i}"))
		missions << t
	    end
	    (1..options[:permanent]).each do |i|
		options[:plan].add_permanent_task(t = options[:model].new(id: "perm-#{i}"))
		permanent << t
	    end
	    (1..(options[:discover] + options[:add])).each do |i|
		options[:plan].add(t = options[:model].new(id: "discover-#{i}"))
		added << t
	    end
	    (1..options[:tasks]).each do |i|
		tasks << options[:model].new(id: "task-#{i}")
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

        def develop_planning_method(method_name, args = Hash.new)
            options, args = Kernel.filter_options args,
                planner_model: MainPlanner

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

