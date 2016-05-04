require 'roby'
require 'optparse'

app = Roby.app
app.require_app_dir
app.public_shell_interface = true
app.public_logs = true

MetaRuby.keep_definition_location = false

run_controller = false
options = OptionParser.new do |opt|
    opt.banner = <<-EOD
roby run [-r ROBOT] [-c] action action action...

Starts the Roby app, optionally starting the controller script in
scripts/controllers/ and/or some explicitly given actions
    EOD

    Roby::Application.common_optparse_setup(opt)

    opt.on '--single', "run without connecting to external server. Support for this is plugin-dependent."  do
        app.single
    end
    opt.on "--simulation", "run in simulation mode. All external tasks will be stubbed internally."  do
        app.simulation
    end
    opt.on '-c', "--controller", "run the controller files and blocks"  do
        run_controller = true
    end
end

has_double_dash = false
extra_args = Array.new
ARGV.delete_if do |arg|
    if arg == '--'
        has_double_dash = true
    elsif has_double_dash
        extra_args << arg
        true
    else false
    end
end

remaining_arguments = options.parse(ARGV)
additional_controller_files = Array.new
if !extra_args.empty?
    additional_controller_files << extra_args.shift
    ARGV.replace(extra_args)
end

additional_model_files = Array.new
actions = Array.new
remaining_arguments.each do |arg|
    if File.file?(arg)
        additional_model_files << arg
    else actions << arg
    end
end

Roby.app.additional_model_files.concat(additional_model_files)

Roby.display_exception do
    app.setup

    Roby.plan.execution_engine.once(description: 'roby run bootup') do
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
            controller_file = Roby.app.find_file("scripts", "controllers", "ROBOT.rb", order: :specific_first) ||
                Roby.app.find_file("controllers", "ROBOT.rb", order: :specific_first)
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

        if additional_controller_files
            additional_controller_files.each do |c|
                Robot.info "loading #{c}"
                load c
            end
        end

        Robot.info "done initialization"
    end
    app.run
end

