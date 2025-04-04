# frozen_string_literal: true

require "utilrb/timepoints"
require "roby/test/error"
require "roby/test/common"
require "roby/test/dsl"
require "roby/test/event_reporter"
require "roby/test/teardown_plans"
require "roby/test/minitest_helpers"
require "roby/test/robot_test_helpers"
require "roby/test/run_planners"
require "timecop"

FlexMock.partials_are_based = true
FlexMock.partials_verify_signatures = true

module Roby
    module Test
        class Spec < Minitest::Spec
            include Test::Assertions
            include Test::TeardownPlans
            include Test::MinitestHelpers
            include Test::RunPlanners
            include Test::RobotTestHelpers
            include Utilrb::Timepoints
            extend DSL

            def app
                Roby.app
            end

            def plan
                app.plan
            end

            def engine
                Roby.warn_deprecated "#engine is deprecated, "\
                                     "use #execution_engine instead"
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
                # Mark every app-defined model as permanent, so that the tests
                # can define their own and get cleanup up properly on teardown
                @models_present_in_setup = Set.new
                app.root_models.each do |root_model|
                    models_present_in_setup << root_model
                    root_model.each_submodel do |m|
                        models_present_in_setup << m
                    end
                end
                register_plan(plan)

                @plan_original_event_logger = plan.event_logger
                plan.event_logger = Roby::Test::EventReporter.new(STDOUT)

                super
            end

            def enable_event_reporting
                plan.event_logger.enabled = true
            end

            def disable_event_reporting
                plan.event_logger.enabled = false
            end

            def teardown
                Timecop.return

                begin
                    super
                rescue ::Exception => e
                    teardown_failure = e
                end

                teardown_registered_plans
                app.run_shutdown_blocks
            ensure
                plan.event_logger = @plan_original_event_logger

                clear_registered_plans
                if teardown_failure
                    raise teardown_failure
                end
            end

            def clear_newly_defined_models
                app.root_models.each do |root_model|
                    ([root_model] + root_model.each_submodel.to_a).each do |m|
                        unless models_present_in_setup.include?(m)
                            m.permanent_model = false
                            m.clear_model
                        end
                    end
                end
            end

            def process_events(timeout: 10, **options, &caller_block)
                Roby.warn_deprecated "do not use #process_events. Use the "\
                                     "expect_execution infrastructure instead"

                exceptions = []
                first_pass = true
                while first_pass || execution_engine.has_waiting_work?
                    first_pass = false

                    execution_engine.join_all_waiting_work(timeout: timeout)
                    execution_engine.start_new_cycle
                    errors = execution_engine.process_events(
                        **options, &caller_block
                    )
                    caller_block = nil
                    exceptions.concat(errors.exceptions)
                    execution_engine.cycle_end({})
                end

                unless exceptions.empty?
                    if exceptions.size == 1
                        raise exceptions.first.exception
                    else
                        raise SynchronousEventProcessingMultipleErrors.new(
                            exceptions.map(&:exception)
                        )
                    end
                end
            end

            # Repeatedly process events until a condition is met
            #
            # @yieldreturn [Boolean] true if the condition is met, false
            #   otherwise
            def process_events_until(timeout: 5, **options)
                Roby.warn_deprecated "do not use #process_events. Use the "\
                                     "expect_execution infrastructure with "\
                                     "the 'achieve' expectation instead"

                start = Time.now
                until yield
                    now = Time.now
                    remaining = timeout - (now - start)
                    if remaining < 0
                        flunk("failed to reach expected condition "\
                              "within #{timeout} seconds")
                    end
                    process_events(timeout: remaining, **options)
                    sleep 0.01
                end
            end

            # @deprecated use capture_log instead
            def inhibit_fatal_messages(&block)
                Roby.warn_deprecated "#{__method__} is deprecated, "\
                                     "use capture_log instead"
                with_log_level(Roby, Logger::FATAL, &block)
            end

            # @deprecated use capture_log instead
            def with_log_level(log_object, level)
                Roby.warn_deprecated "#{__method__} is deprecated, "\
                                     "use capture_log instead"
                log_object = log_object.logger if log_object.respond_to?(:logger)
                current_level = log_object.level
                log_object.level = level

                yield
            ensure
                log_object.level = current_level if current_level
            end

            # @deprecated use {#run_planners} instead
            def roby_run_planner(root_task, recursive: true, **options)
                Roby.warn_deprecated "#{__method__} is deprecated, "\
                                     "use run_planners instead"
                run_planners(root_task, recursive: recursive, **options)
            end

            # Declare what {#roby_run_planner} should use to develop a given
            # task during a test
            #
            # The latest handler registered wins
            #
            # @param [PlanningHandler] a planning handler
            def self.roby_plan_with(matcher, handler)
                RunPlanners.roby_plan_with(matcher, handler)
            end

            # Filters out the test suites that are not enabled by the current
            # Roby configuration
            def run
                begin
                    time_it do
                        self.class.roby_should_run(self, app)
                    end
                rescue Minitest::Skip
                    return Minitest::Result.from(self)
                end

                super
            end
        end

        def self.register_spec_type(spec_type)
            Minitest::Spec.register_spec_type spec_type do |desc, roby_spec: nil|
                (roby_spec == true || (roby_spec.nil? && !Roby::Test.self_test?)) &&
                    yield(desc)
            end
        end

        register_spec_type Spec do |desc|
            desc.kind_of?(Class) && (desc <= Roby::Task)
        end

        register_spec_type Spec do |desc|
            desc == Robot
        end
    end
end
