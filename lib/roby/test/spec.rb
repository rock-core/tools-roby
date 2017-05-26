require 'utilrb/timepoints'
require 'roby/test/error'
require 'roby/test/common'
require 'roby/test/dsl'
require 'roby/test/teardown_plans'
require 'roby/test/minitest_helpers'
require 'timecop'

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
                Timecop.return

                begin
                    super
                rescue ::Exception => e
                    teardown_failure = e
                end

                teardown_registered_plans

            ensure
                clear_registered_plans
                if teardown_failure
                    raise teardown_failure
                end
            end

            def clear_newly_defined_models
                app.root_models.each do |root_model|
                    ([root_model] + root_model.each_submodel.to_a).each do |m|
                        if !models_present_in_setup.include?(m)
                            m.permanent_model = false
                            m.clear_model
                        end
                    end
                end
            end

            def process_events(timeout: 10, **options, &caller_block)
                exceptions = Array.new
                first_pass = true
                while first_pass || execution_engine.has_waiting_work?
                    first_pass = false

                    execution_engine.join_all_waiting_work(timeout: timeout)
                    execution_engine.start_new_cycle
                    errors = execution_engine.process_events(**options, &caller_block)
                    caller_block = nil
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
            def roby_run_planner(root_task, recursive: true, **options)
                if root_task.respond_to?(:as_plan)
                    root_task = root_task.as_plan
                    plan.add_permanent_task(root_task)
                end

                if recursive
                    tasks = plan.task_relation_graph_for(Roby::TaskStructure::Dependency).enum_for(:depth_first_visit, root_task).to_a
                else
                    tasks = [root_task]
                end

                by_handler = tasks.find_all { |t| t.abstract? && t.planning_task }.
                    group_by { |t| Spec.planner_handler_for(t) }.
                    map { |handler_class, tasks| [handler_class.new, tasks] }

                return root_task if by_handler.empty?

                placeholder_tasks = Hash.new
                expect_execution do
                    by_handler.each do |handler, tasks|
                        tasks.each do |t|
                            placeholder_tasks[t] = t.as_service
                        end
                        handler.start(tasks)
                    end
                end.with_setup do
                    scheduler true
                end.to do
                    achieve do
                        by_handler.all? do |handler, tasks|
                            handler.finished?
                        end
                    end
                end

                if placeholder = placeholder_tasks[root_task]
                    root_task = placeholder.to_task
                end

                if recursive
                    roby_run_planner(root_task, recursive: true, **options)
                else
                    root_task
                end
            end

            # Interface for a planning handler for {#roby_run_planner}
            #
            # This class is only used to describe the required interface. See
            # {ActionPlanningHandler} for an example
            class PlanningHandler
                # Start planning these tasks
                #
                # This is called within a propagation context
                def start(tasks)
                    raise NotImplementedError
                end

                # Whether planning is finished for the given tasks
                #
                # This is called within a propagation context
                def finished?
                    raise NotImplementedError
                end
            end

            @@roby_planner_handlers = Array.new

            # @api private
            #
            # Find the handler that should be used by {#roby_run_planner} to
            # plan a given task.
            #
            # @param [Task] task
            # @return [PlanningHandler]
            # @raise ArgumentError
            def self.planner_handler_for(task)
                _, handler_class = @@roby_planner_handlers.find { |matcher, handler| matcher === task }
                if handler_class
                    handler_class
                else
                    raise ArgumentError, "no planning handler found for #{task}"
                end
            end

            # Declare what {#roby_run_planner} should use to develop a given
            # task during a test
            #
            # The latest handler registered wins
            #
            # @param [PlanningHandler] a planning handler
            def self.roby_plan_with(matcher, handler)
                @@roby_planner_handlers.unshift [matcher, handler]
            end


            # Planning handler for {#roby_run_planner} that handles roby action tasks
            class ActionPlanningHandler
                # (see PlanningHandler#start)
                def start(tasks)
                    @planning_tasks = tasks.map(&:planning_task)
                end
                
                # (see PlanningHandler#finished?)
                def finished?
                    @planning_tasks.all?(&:success?)
                end
            end
            roby_plan_with Roby::Task.match.with_child(Roby::Actions::Task), ActionPlanningHandler

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

