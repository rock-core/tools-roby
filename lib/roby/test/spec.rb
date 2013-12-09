require 'roby/test/common'
module Roby
    module Test
        class Spec < MiniTest::Spec
            include Test::Assertions

            class << self
                extend MetaRuby::Attributes
                inherited_attribute(:run_mode, :run_modes) { Array.new }
            end

            def plan; Roby.plan end
            def engine; Roby.plan.engine end

            def setup
                super

                @watch_events_handler_id = engine.add_propagation_handler(:type => :external_events) do |plan|
                    Test.verify_watched_events
                end
            end

            def teardown
                begin
                    super
                rescue ::Exception => e
                    teardown_failure = e
                end

                plan.engine.killall
                if @watch_events_handler_id
                    engine.remove_propagation_handler(@watch_events_handler_id)
                end

            ensure
                if teardown_failure
                    raise teardown_failure
                end
            end

            def process_events
                Roby.app.abort_on_exception = true
                engine.join_all_worker_threads
                engine.start_new_cycle
                engine.process_events
            ensure
                Roby.app.abort_on_exception = false
            end

            def assert_raises(klass)
                super do
                    begin
                        inhibit_fatal_messages do
                            yield
                        end
                    rescue Roby::CodeError => code_error
                        if code_error.error.kind_of?(klass)
                            raise code_error.error
                        else raise
                        end
                    end
                end
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

            # Enable this test in single mode
            #
            # By default, the tests are enabled in all modes. As soon as one of
            # the run_ methods gets called, it is restricted to this particular
            # mode
            def self.run_single
                run_if { |app| app.single? }
            end

            # Enable this test in simulated mode
            #
            # By default, the tests are enabled in all modes. As soon as one of
            # the run_ methods gets called, it is restricted to this particular
            # mode
            def self.run_simulated
                run_if { |app| app.simulation? }
            end

            # Enable this test in live (non-simulated mode)
            #
            # By default, the tests are enabled in all modes. As soon as one of
            # the run_ methods gets called, it is restricted to this particular
            # mode
            def self.run_live
                run_if { |app| !app.simulation? }
            end

            # Enable this test in interactive mode
            #
            # By default, the tests are enabled in all modes. As soon as one of
            # the run_ methods gets called, it is restricted to this particular
            # mode
            def self.run_interactive
                run_if { |app| !app.automatic_testing? }
            end

            # Tests whether self should run on the given app configuration
            #
            # @param [Roby::Application] app
            # @return [Boolean]
            def self.roby_should_run(test, app)
                if each_run_mode.find { true } && each_run_mode.all? { |blk| !blk.call(app) }
                    test.skip("#{test.__name__} cannot run in this roby test configuration")
                end
            end

            # Filters out the test suites that are not enabled by the current
            # Roby configuration
            def run runner
                begin
                    self.class.roby_should_run(self, Roby.app)
                    super
                rescue MiniTest::Skip => e
                    runner.puke self.class, self.__name__, e
                end
            end
        end
    end
end

