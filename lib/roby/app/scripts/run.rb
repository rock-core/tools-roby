require 'roby'

app = Roby.app
app.require_app_dir
app.public_shell_interface = true
app.public_logs = true

run_controller = false
options = OptionParser.new do |opt|
    opt.banner = <<-EOD
roby run [-r ROBOT] [-c] action action action...

Starts the Roby app, optionally starting the controller script in
scripts/controllers/ and/or some explicitly given actions
    EOD

    Roby::Application.common_optparse_setup(opt)

    opt.on '-c', "--controller", "run the controller files and blocks"  do
        run_controller = true
    end
end
remaining_arguments = options.parse(ARGV)

direct_files, actions = remaining_arguments.partition do |arg|
    File.file?(arg)
end
Roby.app.additional_model_files.concat(direct_files)

Roby.display_exception do
    app.setup
    Roby.engine.once do
        Robot.info "loaded Roby on #{RUBY_DESCRIPTION}"

        # Start the requested actions
        actions.each do |act|
            begin
                eval "Robot.#{act}"
            rescue Exception => e
                Robot.warn "cannot start action #{act} specified on the command line"
                Roby.log_exception_with_backtrace(e, Robot, :warn)
            end
        end

        if run_controller
            # Load the controller
            controller_file = Roby.app.find_file("scripts", "controllers", "ROBOT.rb", :order => :specific_first) ||
                Roby.app.find_file("controllers", "ROBOT.rb", :order => :specific_first)
            if controller_file
                Robot.info "loading controller file #{controller_file}"
                load controller_file
            end

            Roby.app.controllers.each do |c|
                c.call
            end

            if Roby.app.controllers.empty? && !controller_file
                Robot.info "no controller block registered, and found no controller file to load for #{Roby.app.robot_name}:#{Roby.app.robot_type}"
            end
        end
        Robot.info "done initialization"
    end
    app.run
end

