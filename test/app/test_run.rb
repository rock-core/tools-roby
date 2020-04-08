# frozen_string_literal: true

require "roby/test/self"
require "roby/test/roby_app_helpers"

module Roby
    describe "run" do
        include Roby::Test::RobyAppHelpers

        describe "single script run call" do
            it "terminates if given an invalid model script" do
                out, = capture_subprocess_io do
                    dir = roby_app_setup_single_script
                    pid = roby_app_spawn("run", "does_not_exist.rb", chdir: dir)
                    roby_app_with_polling(timeout: 10, period: 0.1) do
                        _, status = Process.waitpid2(pid, Process::WNOHANG)
                        if status
                            assert status.exited?
                            assert_equal 1, status.exitstatus
                            true
                        end
                    end
                end
                assert_match(/does_not_exist.rb, given as a model script on the command line, does not exist/, out)
            end

            it "terminates if given an invalid action" do
                out, = capture_subprocess_io do
                    dir = roby_app_setup_single_script
                    pid = roby_app_spawn("run", "does_not_exist", chdir: dir)
                    roby_app_with_polling(timeout: 10, period: 0.1) do
                        _, status = Process.waitpid2(pid, Process::WNOHANG)
                        if status
                            assert status.exited?
                            assert_equal 1, status.exitstatus
                            true
                        end
                    end
                end
                assert_match(/does_not_exist, given as an action on the command line, does not exist/, out)
            end

            it "terminates if given an invalid controller file" do
                out, = capture_subprocess_io do
                    dir = roby_app_setup_single_script
                    pid = roby_app_spawn("run", "--", "does_not_exist.rb", chdir: dir)
                    roby_app_with_polling(timeout: 10, period: 0.1) do
                        _, status = Process.waitpid2(pid, Process::WNOHANG)
                        if status
                            assert status.exited?
                            assert_equal 1, status.exitstatus
                            true
                        end
                    end
                end
                assert_match(/does_not_exist.rb, given as a controller script on the command line, does not exist/, out)
            end

            it "loads files given as argument as model files" do
                dir = roby_app_setup_single_script "is_running.rb"
                out, = capture_subprocess_io do
                    pid = roby_app_spawn("run", "scripts/is_running.rb", chdir: dir)
                    assert_roby_app_quits(pid)
                end
                assert_match(/is_running: false/, out)
            end

            it "allows files given as argument to define new actions" do
                dir = roby_app_setup_single_script "define_action.rb"
                capture_subprocess_io do
                    pid = roby_app_spawn("run", "scripts/define_action.rb", chdir: dir)
                    assert_roby_app_is_running(pid)
                    actions = roby_app_call_remote_interface(&:actions)
                    assert_equal ["action_defined_in_script"], actions.map(&:name)
                    assert_roby_app_quits(pid)
                end
            end

            it "loads the file just after a double dash as a controller file" do
                dir = roby_app_setup_single_script "is_running.rb"
                out, = capture_subprocess_io do
                    pid = roby_app_spawn("run", "--", "scripts/is_running.rb", chdir: dir)
                    assert_roby_app_quits(pid)
                end
                assert_match(/is_running: true/, out)
            end

            it "passes extra arguments to the controller file" do
                dir = roby_app_setup_single_script "controller_arguments.rb"
                out, = capture_subprocess_io do
                    pid = roby_app_spawn("run", "--", "scripts/controller_arguments.rb", "extra", "args", chdir: dir)
                    assert_roby_app_quits(pid)
                end
                assert_match(/ARGV\[0\] = extra\nARGV\[1\] = args/, out)
            end
        end
    end
end
