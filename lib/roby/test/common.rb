# frozen_string_literal: true

require "minitest/spec"
require "roby/test/assertions"
require "flexmock/minitest"
require "timecop"

# simplecov must be loaded FIRST. Only the files required after it gets loaded
# will be profiled !!!
if ENV["TEST_ENABLE_COVERAGE"] == "1" || ENV["TEST_COVERAGE_MODE"]
    mode = ENV["TEST_COVERAGE_MODE"] || "simplecov"
    begin
        require mode
    rescue LoadError => e
        require "roby"
        Roby.warn "coverage is disabled because the code coverage gem cannot be loaded: #{e.message}"
    rescue Exception => e
        require "roby"
        Roby.warn "coverage is disabled: #{e.message}"
    end
end

if ENV["TEST_ENABLE_PRY"] != "0"
    begin
        require "pry"
    rescue Exception
        require "roby"
        Roby.warn "debugging is disabled because the 'pry' gem cannot be loaded"
    end
end

require "roby"

require "roby/test/assertion"
require "roby/test/error"
require "roby/test/minitest_helpers"
require "roby/test/execution_expectations"
require "roby/test/validate_state_machine"
require "roby/test/teardown_plans"

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

        BASE_PORT = 21_000
        DISCOVERY_SERVER = "druby://localhost:#{BASE_PORT}"
        REMOTE_PORT    = BASE_PORT + 1
        LOCAL_PORT     = BASE_PORT + 2
        REMOTE_SERVER  = "druby://localhost:#{BASE_PORT + 3}"
        LOCAL_SERVER   = "druby://localhost:#{BASE_PORT + 4}"

        # The plan used by the tests
        attr_reader :plan
        # The decision control component used by the tests
        attr_reader :control

        @self_test = false

        # Whether we are running Roby's own test suite or not
        #
        # This is used for instance in test/spec to avoid using the Spec
        # classes designed for `roby test` when running Roby's own test suite
        def self.self_test?
            @self_test
        end

        # Set {#self_test?}
        def self.self_test=(flag)
            @self_test = flag
        end

        def execution_engine
            plan.execution_engine if plan&.executable?
        end

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

        attr_reader :app

        def setup
            @app = Roby.app
            @app.development_mode = false
            Roby.app.reload_config
            @log_levels = {}
            @transactions = []

            @plan ||= Roby.app.plan
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
        end

        # @deprecated use {Assertions#capture_log} instead
        def inhibit_fatal_messages(&block)
            Roby.warn_deprecated "##{__method__} is deprecated, use #capture_log instead"
            with_log_level(Roby, Logger::FATAL, &block)
        end

        # @deprecated use {Assertions#capture_log} instead
        def set_log_level(log_object, level)
            Roby.warn_deprecated "#set_log_level is deprecated, use #capture_log instead"
            if log_object.respond_to?(:logger)
                log_object = log_object.logger
            end
            @log_levels[log_object] ||= log_object.level
            log_object.level = level
        end

        # @deprecated use {Assertions#capture_log} instead
        def reset_log_levels(warn_deprecated: true)
            if warn_deprecated
                Roby.warn_deprecated "##{__method__} is deprecated, use #capture_log instead"
            end
            @log_levels.each do |log_object, level|
                log_object.level = level
            end
            @log_levels.clear
        end

        # @deprecated use {Assertions#capture_log} instead
        def with_log_level(log_object, level)
            Roby.warn_deprecated "##{__method__} is deprecated, use #capture_log instead"
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
            Timecop.return

            @transactions.each do |trsc|
                unless trsc.finalized?
                    trsc.discard_transaction
                end
            end
            teardown_registered_plans

            # Plan teardown would have disconnected the peers already
            stop_remote_processes

            restore_collections

            if defined? Roby::Application
                Roby.app.abort_on_exception = false
                Roby.app.abort_on_application_exception = true
            end

            super
        ensure
            reset_log_levels(warn_deprecated: false)
            clear_registered_plans

            if @original_roby_logger_level
                Roby.logger.level = @original_roby_logger_level
            end
        end

        # Process pending events
        def process_events(timeout: 2, enable_scheduler: nil, join_all_waiting_work: true, raise_errors: true, garbage_collect_pass: true, &caller_block)
            Roby.warn_deprecated "Test#process_events is deprecated, use #expect_execution instead"
            exceptions = []
            registered_plans.each do |p|
                engine = p.execution_engine

                loop do
                    engine.start_new_cycle
                    errors =
                        begin
                            current_scheduler_state = engine.scheduler.enabled?
                            unless enable_scheduler.nil?
                                engine.scheduler.enabled = enable_scheduler
                            end

                            engine.process_events(garbage_collect_pass: garbage_collect_pass, &caller_block)
                        ensure
                            engine.scheduler.enabled = current_scheduler_state
                        end

                    if join_all_waiting_work
                        engine.join_all_waiting_work(timeout: timeout)
                    end

                    exceptions.concat(errors.exceptions)
                    engine.cycle_end({})
                    caller_block = nil

                    break unless join_all_waiting_work && engine.has_waiting_work?
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

        # Repeatedly process events until a condition is met
        #
        # @yieldreturn [Boolean] true if the condition is met, false otherwise
        #
        # @param (see #process_events)
        def process_events_until(timeout: 5, join_all_waiting_work: false, **options)
            Roby.warn_deprecated "Test#process_events_until is deprecated, use #expect_execution.to { achieve { ... } } instead"
            start = Time.now
            while !yield
                now = Time.now
                remaining = timeout - (now - start)
                if remaining < 0
                    flunk("failed to reach condition #{proc} within #{timeout} seconds")
                end
                process_events(timeout: remaining, join_all_waiting_work: join_all_waiting_work, **options)
                sleep 0.01
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
        #       discover: 3, tasks: 2
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

            result
        end

        def make_random_plan(plan = Plan.new, tasks: 5, free_events: 5, task_relations: 5, event_relations: 5)
            tasks = (0...tasks).map do
                plan.add(t = Roby::Task.new)
                t
            end
            free_events = (0...free_events).map do
                plan.add(e = Roby::EventGenerator.new)
                e
            end
            events = (free_events + plan.task_events.to_a)

            task_relations.times do
                a = rand(tasks.size)
                b = rand(tasks.size)
                loop do
                    begin
                        tasks[a].depends_on tasks[b]
                        break
                    rescue Exception
                        b = rand(tasks.size)
                    end
                end
            end

            event_relations.times do
                a = rand(events.size)
                b = rand(events.size)
                loop do
                    begin
                        events[a].forward_to events[b]
                        break
                    rescue Exception
                        b = rand(events.size)
                    end
                end
            end
            plan
        end

        # Start a new process and saves its PID in #remote_processes. If a block is
        # given, it is called in the new child. #remote_process returns only after
        # this block has returned.
        def remote_process
            start_r, start_w = IO.pipe
            quit_r, quit_w = IO.pipe
            remote_pid = fork do
                begin
                    start_r.close
                    yield
                rescue Exception => e
                    puts e.full_message
                end

                start_w.write("OK")
                quit_r.read(2)
            end
            start_w.close
            result = start_r.read(2)

            remote_processes << [remote_pid, quit_w]
            remote_pid
        ensure
            start_r.close
        end

        # Stop all the remote processes that have been started using #remote_process
        def stop_remote_processes
            remote_processes.reverse.each do |pid, quit_w|
                begin
                    quit_w.write("OK")
                rescue Errno::EPIPE
                end
                begin
                    Process.waitpid(pid)
                rescue Errno::ECHILD
                end
            end
            remote_processes.clear
        end
    end
end
