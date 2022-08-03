# frozen_string_literal: true

require "roby"
require "optparse"

app = Roby.app
app.require_app_dir
app.public_shell_interface = true
app.public_logs = true
app.public_log_server = true

# Reset any disposition about INT, the run behavior depends on its behavior (and
# this is the CLI)
trap "INT", "DEFAULT"

MetaRuby.keep_definition_location = false

run_controller = false
wait_shell_connection = false
options = OptionParser.new do |opt|
    opt.banner = <<~BANNER_TEXT
        roby run [-r ROBOT] [-c] action action action...

        Starts the Roby app, optionally starting the controller script in
        scripts/controllers/ and/or some explicitly given actions
    BANNER_TEXT

    Roby::Application.common_optparse_setup(opt)

    opt.on "--quiet" do
        Roby.logger.level = Logger::WARN
        Robot.logger.level = Logger::WARN
    end
    opt.on "--log-dir=DIR", String, "explicitely set the log dir (must exist)" do |dir|
        app.log_dir = dir
        app.log_create_current = false
    end
    opt.on "--port=PORT", Integer, "the interface port" do |port|
        app.shell_interface_port = port
    end
    opt.on "--no-interface", "disable the shell interface" do
        app.public_shell_interface = false
    end
    opt.on "--no-logs", "treat the log directory as ephemeral" do
        app.public_logs = false
    end
    opt.on "--log-timepoints", "log internal Roby timings" do
        app.log_timepoints = true
    end
    opt.on "--wait-shell-connection", "wait for a shell connection before running" do
        wait_shell_connection = true
    end
    opt.on "--rest[=SOCKET_OR_PORT]", String, "enable the experimental REST API" do |socket|
        app.public_rest_interface = true
        if socket =~ /^\d+$/
            app.rest_interface_port = Integer(socket)
        else
            app.rest_interface_host = socket
        end
    end
    opt.on "--single", "run without connecting to external server. Support for this is plugin-dependent." do
        app.single
    end
    opt.on "--production", "run in production mode, disabling all development-related functionality" do
        app.development_mode = false
    end
    opt.on "--simulation", "run in simulation mode. All external tasks will be stubbed internally." do
        app.simulation
    end
    opt.on "-c", "--controller", "run the controller files and blocks" do
        run_controller = true
    end
    opt.on "-p", "--plugin=PLUGIN", String, "load this plugin" do |plugin|
        Roby.app.using plugin
    end
end

has_double_dash = false
extra_args = []
ARGV.delete_if do |arg|
    if arg == "--"
        has_double_dash = true
    elsif has_double_dash
        extra_args << arg
        true
    else false
    end
end

remaining_arguments = options.parse(ARGV)
additional_controller_files = []
unless extra_args.empty?
    additional_controller_files << extra_args.shift
    ARGV.replace(extra_args)
end

additional_controller_files.each do |file|
    unless File.file?(file)
        Roby.error "#{file}, given as a controller script on the command line, does not exist"
        exit 1
    end
end

additional_model_files = []
actions = []
remaining_arguments.each do |arg|
    if File.file?(arg)
        additional_model_files << File.expand_path(arg)
    elsif File.extname(arg) == ".rb"
        Roby.error "#{arg}, given as a model script on the command line, does not exist"
        exit 1
    else actions << arg
    end
end
Roby.app.additional_model_files.concat(additional_model_files)

error = Roby.display_exception(STDERR) do
    begin
        app.setup
        actions = actions.map do |act_name|
            _, action = Roby.app.find_action_from_name(act_name)
            unless action
                Robot.error "#{act_name}, given as an action on the command line, does not exist"
                exit 1
            end
            action
        end

        engine = Roby.plan.execution_engine

        engine.once do
            Robot.info "loaded Roby on #{RUBY_DESCRIPTION}"
        end

        handler = Roby.plan.execution_engine.each_cycle(description: "roby run bootup") do
            if wait_shell_connection &&
               Roby.app.shell_interface.client_count(handshake: true) == 0
                next
            end

            # Start the requested actions
            actions.each do |act|
                Roby.plan.add_mission_task(act.plan_pattern)
            end

            if run_controller
                # Load the controller
                controller_file =
                    Roby.app.find_file("scripts", "controllers", "ROBOT.rb",
                                       order: :specific_first) ||
                    Roby.app.find_file("controllers", "ROBOT.rb", order: :specific_first)
                if controller_file
                    Robot.info "loading controller file #{controller_file}"
                    load controller_file
                end

                Roby.app.run_controller_blocks

                if Roby.app.controllers.empty? && !controller_file
                    Robot.info "no controller block registered, and found "\
                               "no controller file to load for "\
                               "#{Roby.app.robot_name}:#{Roby.app.robot_type}"
                end
            end

            additional_controller_files&.each do |c|
                Robot.info "loading #{c}"
                load c
            end

            Robot.info "done initialization"
            Robot.info "ready"
            handler.dispose
        end
        app.run(thread_priority: -1)
    ensure
        app.cleanup
    end
end

if app.restarting?
    app.restart!
elsif error
    exit 1
end
