# frozen_string_literal: true

require "roby/test/self"
require "roby/test/aruba_minitest"

module Roby
    module CLI
        describe "roby gen" do
            include Test::ArubaMinitest

            def validate_app_runs(*args)
                roby_run = run_roby ["run", *args].join(" ")
                run_roby_and_stop "quit --retry"
                roby_run.stop
                assert_command_finished_successfully roby_run
            end

            def validate_app_tests
                roby_run = run_command "rake test", environment: { RUBOCOP: 1 }
                roby_run.stop
                assert_command_finished_successfully roby_run
            end

            describe "creation of a new app in the current directory" do
                it "generates a new valid app" do
                    run_roby_and_stop "gen app"
                    validate_app_runs
                    validate_app_tests
                end

                it "generates a default robot configuration" do
                    run_roby_and_stop "gen app"
                    assert file?("config/robots/default.rb")
                end

                it "is accessible through the deprecated 'init' subcommand" do
                    run_roby_and_stop "init"
                    validate_app_runs
                end
            end

            describe "within an existing app" do
                before do
                    run_roby_and_stop "gen app"
                end

                describe "gen robot" do
                    it "generates a new valid robot configuration" do
                        run_roby_and_stop "gen robot test"
                        validate_app_runs "-rtest"
                        validate_app_tests
                    end
                end
            end
        end
    end
end
