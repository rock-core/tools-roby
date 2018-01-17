require 'roby/test/self'
require 'roby/cli/main'
require 'roby/test/aruba_minitest'

module Roby
    module CLI
        describe Main do
            include Roby::Test::ArubaMinitest

            describe "quit" do
                before do
                    run_command_and_stop "roby gen app"
                end
                it "exits with a nonzero status if there is no app to quit" do
                    cmd = run_command "roby quit"
                    cmd.stop
                    assert_equal 1, cmd.exit_status
                end
                it "stops a running app" do
                    run_cmd = run_command "roby run"
                    run_command_and_stop "roby wait"
                    run_command_and_stop "roby quit"
                    assert_command_stops run_cmd
                end
                it "stops a running app on another port" do
                    run_cmd = run_command "roby run --port 9999"
                    run_command_and_stop "roby wait --host localhost:9999"
                    run_command_and_stop "roby quit --host localhost:9999"
                    assert_command_stops run_cmd
                end
                it "waits forever for the app to be available if --retry is given" do
                    run_cmd = run_command "roby run"
                    run_command_and_stop "roby quit --retry"
                    assert_command_stops run_cmd
                end
                it "times out on retrying if --retry is given a timeout" do
                    before = Time.now
                    cmd = run_command "roby quit --retry=1"
                    cmd.stop
                    assert_equal 1, cmd.exit_status
                    assert (Time.now - before) > 1
                end
            end
        end
    end
end
