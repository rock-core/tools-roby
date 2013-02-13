require 'roby'

run_controller = false
options = OptionParser.new do |opt|
    opt.banner = <<-EOD
roby run [-r ROBOT] [-c] action action action...

Starts the Roby app, optionally starting the controller script in
scripts/controllers/ and/or some explicitly given actions

    EOD
    opt.on "--robot NAME[:TYPE]", '-r NAME[:TYPE', "the robot configuration to load" do |robot_desc|
        robot_name, robot_type = robot_desc.split(':')
        app.robot robot_name, (robot_type || robot_name)
    end
    opt.on "--controller", '-c', "run the controller file"  do
        run_controller = true
    end
    opt.on "--help", "-h", "this help message" do
        puts options
        exit 1
    end
end
actions = options.parse(ARGV)

app = Roby.app
app.require_app_dir
app.public_shell_interface = true
app.public_logs = true

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

	# Load the controller
        controller_file = Roby.app.find_file("scripts", "controllers", "ROBOT.rb", :order => :specific_first) ||
            Roby.app.find_file("controllers", "ROBOT.rb", :order => :specific_first)
        if controller_file
            Robot.info "loading controller file #{controller_file}"
            load controller_file
        else
            Robot.info "found no controller file to load"
        end
        Robot.info "done initialization"
    end
    app.run
end

