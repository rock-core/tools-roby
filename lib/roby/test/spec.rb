require 'utilrb/timepoints'
require 'roby/test/error'
require 'roby/test/common'
require 'roby/test/dsl'
require 'roby/test/teardown_plans'
require 'roby/test/minitest_helpers'

FlexMock.partials_are_based = true
FlexMock.partials_verify_signatures = true

module Roby
    module Test
        class Spec < Minitest::Spec
            include Test::Assertions
            include Test::TeardownPlans
            include Test::MinitestHelpers
            include Utilrb::Timepoints
            extend DSL

            def app
                Roby.app
            end
            def plan
                app.plan
            end
            def engine
                Roby.warn_deprecated "#engine is deprecated, use #execution_engine instead"
                execution_engine
            end
            def execution_engine
                app.execution_engine
            end

            def self.test_methods
                methods = super
                # Duplicate each method 'repeat' times
                methods.inject([]) do |list, m|
                    list.concat([m] * Roby.app.test_repeat)
                end
            end

            def __full_name__
                "#{self.class}##{name}"
            end

            # Set of models present during {#setup}
            #
            # This is used to clear all the models created during the test in
            # {#teardown}
            attr_reader :models_present_in_setup

            def setup
                plan.execution_engine.display_exceptions = false
                # Mark every app-defined model as permanent, so that the tests can define
                # their own and get cleanup up properly on teardown
                @models_present_in_setup = Set.new
                app.root_models.each do |root_model|
                    models_present_in_setup << root_model
                    root_model.each_submodel do |m|
                        models_present_in_setup << m
                    end
                end
                register_plan(plan)

                super
            end

            def teardown
                begin
                    super
                rescue ::Exception => e
                    teardown_failure = e
                end

                teardown_registered_plans

                app.root_models.each do |root_model|
                    ([root_model] + root_model.each_submodel.to_a).each do |m|
                        if !models_present_in_setup.include?(m)
                            m.permanent_model = false
                            m.clear_model
                        end
                    end
                end

            ensure
                clear_registered_plans
                if teardown_failure
                    raise teardown_failure
                end
            end

            def process_events(timeout: 10, **options)
                exceptions = Array.new
                first_pass = true
                while first_pass || execution_engine.has_waiting_work?
                    first_pass = false

                    execution_engine.join_all_waiting_work(timeout: timeout)
                    execution_engine.start_new_cycle
                    errors = execution_engine.process_events(**options)
                    exceptions.concat(errors.exceptions)
                    execution_engine.cycle_end(Hash.new)
                end

                if !exceptions.empty?
                    if exceptions.size == 1
                        raise exceptions.first.exception
                    else
                        raise SynchronousEventProcessingMultipleErrors.new(exceptions.map(&:exception))
                    end
                end
            end

            # Repeatedly process events until a condition is met
            #
            # @yieldreturn [Boolean] true if the condition is met, false otherwise
            def process_events_until(timeout: 5, **options)
                start = Time.now
                while !yield
                    now = Time.now
                    remaining = timeout - (now - start)
                    if remaining < 0
                        flunk("failed to reach expected condition within #{timeout} seconds")
                    end
                    process_events(timeout: remaining, **options)
                    sleep 0.01
                end
            end

            def inhibit_fatal_messages(&block)
                with_log_level(Roby, Logger::FATAL, &block)
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

            # Plan the given task
            def roby_run_planner(task, recursive: true)
                if task.respond_to?(:as_plan)
                    task = task.as_plan
                    plan.add_permanent_task(task)
                end

                while (planner = task.planning_task) && !planner.finished?
                    handler = Spec.planner_handler_for(task)
                    task = instance_exec(task, &handler.block)
                    break if !recursive
                end
                task
            end

            # Handler used by {#roby_run_planner} to develop a subplan
            PlanningHandler = Struct.new :matcher, :block do
                def call(task); block.call(task) end
                def ===(task); matcher === task end
            end

            @@roby_planner_handlers = Array.new

            # @api private
            #
            # Find the handler that should be used by {#roby_run_planner}
            def self.planner_handler_for(task)
                if handler = @@roby_planner_handlers.find { |handler| handler === task }
                    handler
                else
                    raise ArgumentError, "no planning handler found for #{task}"
                end
            end

            # Declare what {#roby_run_planner} should use to develop a given
            # task during a test
            #
            # The default is to simply start the planner and wait for it to
            # finish
            #
            # The latest handler registered wins
            def self.roby_plan_with(matcher, &block)
                @@roby_planner_handlers.unshift PlanningHandler.new(matcher, block)
            end

            roby_plan_with Roby::Task.match.with_child(Roby::Actions::Task) do |task|
                placeholder = task.as_service
                assert_event_emission task.planning_task.success_event
                placeholder.to_task
            end

            # Filters out the test suites that are not enabled by the current
            # Roby configuration
            def run
                time_it do
                    capture_exceptions do
                        self.class.roby_should_run(self, app)
                        super
                    end
                end
                self
            end

        end
    end

    Minitest::Spec.register_spec_type Roby::Test::Spec do |desc|
        desc.kind_of?(Class) && (desc <= Roby::Task)
    end
end

