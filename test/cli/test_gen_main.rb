require 'roby/test/self'
require 'roby/test/aruba_minitest'

module Roby
    module CLI
        describe 'roby gen' do
            include Test::ArubaMinitest

            def validate_app_valid(*args)
                roby_run  = run_command ["roby", "run", *args].join(" ")
                run_command_and_stop "roby quit --retry"
                roby_run.stop
                assert_command_finished_successfully roby_run
            end

            describe "creation of a new app in the current directory" do
                it "generates a new valid app" do
                    run_command_and_stop "roby gen app"
                    validate_app_valid
                end

                it "generates a default robot configuration" do
                    run_command_and_stop "roby gen app"
                    assert file?('config/robots/default.rb')
                end

                it "is accessible through the deprecated 'init' subcommand" do
                    run_command_and_stop "roby init"
                    validate_app_valid
                end
            end

            describe "within an existing app" do
                before do
                    run_command_and_stop "roby gen app"
                end

                describe "gen robot" do
                    it "generates a new valid robot configuration" do
                        run_command_and_stop "roby gen robot test"
                        validate_app_valid "-rtest"
                    end
                end
            end
        end
    end
end

