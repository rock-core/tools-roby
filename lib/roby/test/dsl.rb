module Roby
    module Test
        module DSL
            include Minitest::Spec::DSL

            extend MetaRuby::Attributes
            inherited_attribute(:run_mode, :run_modes) { Array.new }
            inherited_attribute(:enabled_robot, :enabled_robots) { Set.new }

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
            def run_if(&block)
                run_modes << lambda(&block)
            end

            # Enable this test only on the given robot
            def run_on_robot(*robot_names, &block)
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
            def run_single(&block)
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
            def run_simulated(&block)
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
            def run_live(&block)
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
            def run_interactive(&block)
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
            def roby_should_run(test, app)
                run_modes = all_run_mode
                enabled_robots = all_enabled_robot
                if !run_modes.empty? && run_modes.all? { |blk| !blk.call(app) }
                    test.skip("#{test.name} cannot run in this roby test configuration")
                elsif !enabled_robots.empty? && !enabled_robots.include?(app.robot_name)
                    test.skip("#{test.name} can only be run on robots #{enabled_robots.sort.join(", ")}")
                end
            end

            # Register sub-hooks
            def describe(*desc, &block)
                behaviour = Module.new do
                    extend Roby::Test::DSL
                    class_eval(&block)
                end

                @__describe_blocks ||= Array.new
                @__describe_blocks << [desc, behaviour]
            end

            def self.included(target)
                super

                @__describe_blocks ||= Array.new
                if Class === target
                    @__describe_blocks.each do |desc, behaviour|
                        target.describe(desc) { include behaviour }
                    end
                else
                    target.instance_variable_get(:@__describe_blocks).
                        concat(@__describe_blocks)
                end
            end
        end
    end
end

