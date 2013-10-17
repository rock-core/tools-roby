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

    opt.on '-c', "--controller", "run the controller file"  do
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
        if defined? RUBY_DESCRIPTION
            Robot.info "loaded Roby #{Roby::VERSION} on #{RUBY_DESCRIPTION}"
        else
            Robot.info "loaded Roby #{Roby::VERSION}"
        end

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
            else
                Robot.info "found no controller file to load"
            end
        end
        Robot.info "done initialization"
    end
    app.run
end

