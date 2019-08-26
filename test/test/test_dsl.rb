require 'roby/test/self'
require 'roby/test/roby_app_helpers'
require 'roby/test/dsl'

module Roby
    module Test
        describe DSL do
            include Roby::Test::RobyAppHelpers

            it 'skips tests that are run_on_robot for a different robot' do
                out = capture_test_output do
                    dir = roby_app_setup_single_script 'run_if.rb'
                    run_test dir
                end
                assert_equal Set['TEST: all', 'TEST: simulated'], out
            end

            it 'runs tests that are run_on_robot for the selected robot' do
                out = capture_test_output do
                    dir = roby_app_setup_single_script 'run_if.rb'
                    FileUtils.touch File.join(dir, 'config', 'robots', 'special_robot.rb')
                    run_test dir, '--robot=special_robot'
                end
                assert_equal Set['TEST: all', 'TEST: simulated', 'TEST: special_robot'],
                             out
            end

            it 'skips tests that are "run_live" and runs those that are run_simulated if in live mode' do
                out = capture_test_output do
                    dir = roby_app_setup_single_script 'run_if.rb'
                    run_test dir
                end
                assert_equal Set['TEST: all', 'TEST: simulated'], out
            end

            it 'runs tests that are "run_live" and skips those that are run_simulated if in live mode' do
                out = capture_test_output do
                    dir = roby_app_setup_single_script 'run_if.rb'
                    run_test dir, '--live'
                end
                assert_equal Set['TEST: all', 'TEST: live'], out
            end

            def capture_test_output(&block)
                out, _ = capture_subprocess_io(&block)
                out.split("\n").map(&:chomp).grep(/^TEST: /).to_set
            end

            def run_test(dir, *args)
                roby_app_run('test', *args, 'scripts/run_if.rb', chdir: dir)
            end
        end
    end
end
