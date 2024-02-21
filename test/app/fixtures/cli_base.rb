# frozen_string_literal: true

require "roby/cli/base"

class CLI < Roby::CLI::Base
    desc "cmd", "the command"
    option :robot
    option :controllers, type: :boolean, default: false
    option :port, type: :numeric, default: Roby::Interface::DEFAULT_PORT
    def cmd
        setup_common
        app.log_server = false
        app.log_setup "roby", "FATAL"
        setup_roby_for_running(run_controllers: options[:controllers])
        app.setup
        begin
            Robot.controller do
                FileUtils.touch File.join(app.app_dir, "created_by_controller")
            end
            app.run
        ensure
            app.cleanup
        end
    end
end

CLI.start(ARGV)
