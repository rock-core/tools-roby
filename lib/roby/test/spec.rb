require 'utilrb/timepoints'
require 'roby/test/error'
require 'roby/test/common'
require 'roby/test/teardown_plans'
require 'roby/test/minitest_helpers'
module Roby
    module Test
        class Spec < Minitest::Spec
            include Test::Assertions
            include Test::TeardownPlans
            include Test::MinitestHelpers
            include Utilrb::Timepoints

            class << self
                extend MetaRuby::Attributes
                inherited_attribute(:run_mode, :run_modes) { Array.new }
                inherited_attribute(:enabled_robot, :enabled_robots) { Set.new }
            end

            def app; Roby.app end
            def plan; app.plan end
            def engine
                Roby.warn_deprecated "#engine is deprecated, use #execution_engine instead"
                execution_engine
            end
            def execution_engine; app.execution_engine end

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
                Roby.app.root_models.each do |root_model|
                    models_present_in_setup << root_model
                    root_model.each_submodel do |m|
                        models_present_in_setup << m
                    end
                end
                register_plan(Roby.plan)

                super

                @watch_events_handler_id = execution_engine.add_propagation_handler(type: :external_events) do |plan|
                    verify_watched_events
                end
                @received_exceptions = Array.new
                @exception_handler = execution_engine.on_exception do |kind, e|
                    @received_exceptions << [kind, e]

                end
            end

            def teardown
                begin
                    super
                rescue ::Exception => e
                    teardown_failure = e
                end

                teardown_registered_plans
                if @watch_events_handler_id
                    execution_engine.remove_propagation_handler(@watch_events_handler_id)
                end

                Roby.app.root_models.each do |root_model|
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

            def process_events
                @received_exceptions.clear
                execution_engine.join_all_waiting_work
                execution_engine.start_new_cycle
                execution_engine.process_events
                @received_exceptions.each do |kind, e|
                    if kind == Roby::ExecutionEngine::EXCEPTION_FATAL
                        raise e
                    end
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

            # Enable this test only on the configurations in which the given
            # block returns true
            #
            # If more than one call to the run_ methods is given, the test will
            # run as soon as at least one of the conditions is met
            #
            # @yieldparam [Roby::Application] app
            # @yieldreturn [Boolean] true if the spec should run, false
            # otherwise
            #
            # By default, the tests are enabled in all modes. As soon as one of
            # the run_ methods gets called, it is restricted to this particular
            # mode
            def self.run_if(&block)
                run_modes << lambda(&block)
            end

            # Enable this test only on the given robot
            def self.run_on_robot(*robot_names, &block)
                if block
                    describe "in interactive mode" do
                        run_on_robot(*robot_names)
                        class_eval(&block)
                    end
                else
                    enabled_robots.merge(robot_names)
                end
            end

            # Enable this test in single mode
            #
            # By default, the tests are enabled in all modes. As soon as one of
            # the run_ methods gets called, it is restricted to this particular
            # mode
            def self.run_single(&block)
                if block
                    describe "in single mode" do
                        run_single
                        class_eval(&block)
                    end
                else
                    run_if { |app| app.single? }
                end
            end

            # Enable this test in simulated mode
            #
            # By default, the tests are enabled in all modes. As soon as one of
            # the run_ methods gets called, it is restricted to this particular
            # mode
            def self.run_simulated(&block)
                if block
                    describe "in simulation mode" do
                        run_simulated
                        class_eval(&block)
                    end
                else
                    run_if { |app| app.simulation? }
                end
            end

            # Enable this test in live (non-simulated mode)
            #
            # By default, the tests are enabled in all modes. As soon as one of
            # the run_ methods gets called, it is restricted to this particular
            # mode
            def self.run_live(&block)
                if block
                    describe "in live mode" do
                        run_live
                        class_eval(&block)
                    end
                else
                    run_if { |app| !app.simulation? }
                end
            end

            # Enable this test in interactive mode
            #
            # By default, the tests are enabled in all modes. As soon as one of
            # the run_ methods gets called, it is restricted to this particular
            # mode
            def self.run_interactive(&block)
                if block
                    describe "in interactive mode" do
                        run_interactive
                        class_eval(&block)
                    end
                else
                    run_if { |app| !app.automatic_testing? }
                end
            end

            # Tests whether self should run on the given app configuration
            #
            # @param [Roby::Application] app
            # @return [Boolean]
            def self.roby_should_run(test, app)
                run_modes = all_run_mode
                enabled_robots = all_enabled_robot
                if !run_modes.empty? && run_modes.all? { |blk| !blk.call(app) }
                    test.skip("#{test.name} cannot run in this roby test configuration")
                elsif !enabled_robots.empty? && !enabled_robots.include?(app.robot_name)
                    test.skip("#{test.name} can only be run on robots #{enabled_robots.sort.join(", ")}")
                end
            end

            # Filters out the test suites that are not enabled by the current
            # Roby configuration
            def run
                time_it do
                    capture_exceptions do
                        self.class.roby_should_run(self, Roby.app)
                        super
                    end
                end
                self
            end

        end
    end

    Minitest::Spec.register_spec_type Roby::Test::Spec do |desc|
        desc <= Roby::Task
    end
end

