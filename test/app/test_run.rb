# frozen_string_literal: true

require "roby/test/self"
require "roby/test/roby_app_helpers"
require "roby/test/aruba_minitest"

module Roby
    describe "run" do
        describe "robot argument" do
            include Test::ArubaMinitest
            before do
                run_roby_and_stop "gen app --quiet"
            end

            describe "deprecated behavior not using the config/robots/ folder" do
                before do
                    FileUtils.rm_rf expand_path("config/robots")
                end

                it "uses a name given to -r as name and type by default" do
                    write_file "scripts/controllers/somename.rb", <<~DISPLAY
                        puts "Roby.app.robot_name=\#{Roby.app.robot_name}"
                        puts "Roby.app.robot_type=\#{Roby.app.robot_type}"
                    DISPLAY

                    cmd = run_roby "run -r somename -c"
                    run_roby_and_stop "wait"
                    run_roby_and_stop "quit"

                    assert_match(/^Roby.app.robot_name=somename$/, cmd.stdout)
                    assert_match(/^Roby.app.robot_type=somename$/, cmd.stdout)
                end

                it "uses the name and type given to -r" do
                    write_file "scripts/controllers/somename.rb", <<~DISPLAY
                        puts "Roby.app.robot_name=\#{Roby.app.robot_name}"
                        puts "Roby.app.robot_type=\#{Roby.app.robot_type}"
                    DISPLAY

                    cmd = run_roby "run -r somename,sometype -c"
                    run_roby_and_stop "wait"
                    run_roby_and_stop "quit"

                    assert_match(/^Roby.app.robot_name=somename$/, cmd.stdout)
                    assert_match(/^Roby.app.robot_type=sometype$/, cmd.stdout)
                end

                it "runs the controller script named as the type if there is none "\
                   "for the robot name" do
                    write_file "scripts/controllers/sometype.rb", <<~DISPLAY
                        puts "Roby.app.robot_name=\#{Roby.app.robot_name}"
                        puts "Roby.app.robot_type=\#{Roby.app.robot_type}"
                    DISPLAY

                    cmd = run_roby "run -r somename,sometype -c"
                    run_roby_and_stop "wait"
                    run_roby_and_stop "quit"

                    assert_match(/^Roby.app.robot_name=somename$/, cmd.stdout)
                    assert_match(/^Roby.app.robot_type=sometype$/, cmd.stdout)
                end
            end

            it "stops on CTRL+C" do
                cmd = run_roby "run"
                run_roby_and_stop "wait"
                cmd.send_signal "INT"
                cmd.wait
            end

            it "properly brings the system down on CTRL+C" do
                write_file "config/robots/somename.rb", <<~DISPLAY
                    require "roby/tasks/simple"
                    Robot.controller do
                        task = Roby::Tasks::Simple.new
                        task.start_event.on { puts "TASK STARTED" }
                        task.stop_event.on { puts "TASK STOPPED" }
                        Roby.plan.add_mission_task(task)
                        task.start!
                    end
                DISPLAY

                cmd = run_roby "run -rsomename -c"
                wait_for_output(cmd, :stdout) { |out| out.match?(/TASK STARTED/) }
                cmd.send_signal "INT"
                cmd.stop
                assert_match(/TASK STOPPED/, cmd.stdout)
            end

            it "raises if configuration files exist in config/robots/ "\
               "and the robot name does not match one" do
                cmd = run_roby_and_stop "run -r somename", fail_on_error: false
                assert_equal 1, cmd.exit_status

                assert_match(/somename is neither a robot name, nor an alias/,
                             cmd.stderr)
            end

            describe "strict robot naming" do
                before do
                    write_file "config/robots/somename.rb", <<~DISPLAY
                        puts "Roby.app.robot_name=\#{Roby.app.robot_name}"
                        puts "Roby.app.robot_type=\#{Roby.app.robot_type}"
                    DISPLAY
                end

                it "uses the files in config/robots/ to determine the list of "\
                   "available names" do
                    cmd = run_roby "run -r somename"
                    run_roby_and_stop "wait"
                    run_roby_and_stop "quit"

                    assert_match(/^Roby.app.robot_name=somename$/, cmd.stdout)
                    assert_match(/^Roby.app.robot_type=somename$/, cmd.stdout)
                end

                it "uses the robot type as defined in app.yml" do
                    write_file "config/app.yml", <<~APPYML
                        robots:
                            robots:
                                somename: sometype
                    APPYML

                    cmd = run_roby "run -r somename"
                    run_roby_and_stop "wait"
                    run_roby_and_stop "quit"

                    assert_match(/^Roby.app.robot_name=somename$/, cmd.stdout)
                    assert_match(/^Roby.app.robot_type=sometype$/, cmd.stdout)
                end

                it "uses the default robot as defined in app.yml" do
                    write_file "config/app.yml", <<~APPYML
                        robots:
                            default_robot: somename
                    APPYML

                    cmd = run_roby "run"
                    run_roby_and_stop "wait"
                    run_roby_and_stop "quit"

                    assert_match(/^Roby.app.robot_name=somename$/, cmd.stdout)
                    assert_match(/^Roby.app.robot_type=somename$/, cmd.stdout)
                end

                it "applies the declared type for the default robot" do
                    write_file "config/app.yml", <<~APPYML
                        robots:
                            default_robot: somename
                            robots:
                                somename: sometype
                    APPYML

                    cmd = run_roby "run"
                    run_roby_and_stop "wait"
                    run_roby_and_stop "quit"

                    assert_match(/^Roby.app.robot_name=somename$/, cmd.stdout)
                    assert_match(/^Roby.app.robot_type=sometype$/, cmd.stdout)
                end
            end
        end

        describe "single script run call" do
            include Roby::Test::RobyAppHelpers

            it "terminates if given an invalid model script" do
                out, = capture_subprocess_io do
                    dir = roby_app_setup_single_script
                    pid = roby_app_spawn("run", "does_not_exist.rb", chdir: dir)
                    status = assert_roby_app_exits(pid)
                    assert_equal 1, status.exitstatus
                end
                assert_match(/does_not_exist.rb, given as a model script on the command line, does not exist/, out)
            end

            it "terminates if given an invalid action" do
                out, = capture_subprocess_io do
                    dir = roby_app_setup_single_script
                    pid = roby_app_spawn("run", "does_not_exist", chdir: dir)
                    status = assert_roby_app_exits(pid)
                    assert_equal 1, status.exitstatus
                end
                assert_match(/does_not_exist, given as an action on the command line, does not exist/, out)
            end

            it "terminates if given an invalid controller file" do
                out, = capture_subprocess_io do
                    dir = roby_app_setup_single_script
                    pid = roby_app_spawn("run", "--", "does_not_exist.rb", chdir: dir)
                    status = assert_roby_app_exits(pid)
                    assert_equal 1, status.exitstatus
                end
                assert_match(/does_not_exist.rb, given as a controller script on the command line, does not exist/, out)
            end

            it "loads files given as argument as model files" do
                dir = roby_app_setup_single_script "is_running.rb"
                out, = capture_subprocess_io do
                    pid = roby_app_spawn("run", "scripts/is_running.rb", chdir: dir)
                    assert_roby_app_exits(pid)
                end
                assert_match(/is_running: false/, out)
            end

            it "allows files given as argument to define new actions" do
                dir = roby_app_setup_single_script "define_action.rb"
                capture_subprocess_io do
                    pid, interface =
                        roby_app_start("run", "scripts/define_action.rb", chdir: dir)
                    actions = interface.actions
                    assert_equal ["action_defined_in_script"], actions.map(&:name)
                    assert_roby_app_quits(pid, interface: interface)
                end
            end

            it "loads the file just after a double dash as a controller file" do
                dir = roby_app_setup_single_script "is_running.rb"
                out, = capture_subprocess_io do
                    pid = roby_app_spawn("run", "--", "scripts/is_running.rb", chdir: dir)
                    assert_roby_app_exits(pid)
                end
                assert_match(/is_running: true/, out)
            end

            it "passes extra arguments to the controller file" do
                dir = roby_app_setup_single_script "controller_arguments.rb"
                out, = capture_subprocess_io do
                    pid = roby_app_spawn(
                        "run", "--", "scripts/controller_arguments.rb", "extra", "args",
                        chdir: dir
                    )
                    assert_roby_app_exits(pid)
                end
                assert_match(/ARGV\[0\] = extra\nARGV\[1\] = args/, out)
            end
        end
    end
end
