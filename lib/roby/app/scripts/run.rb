require File.join(File.dirname(__FILE__), '..', 'run')
app = Roby.app

robot_name = ARGV.shift
app.robot robot_name, (ARGV.shift || robot_name)
app.setup
begin
    app.run do
        if defined? RUBY_DESCRIPTION
            Robot.info "loaded Roby #{Roby::VERSION} on #{RUBY_DESCRIPTION}"
        else
            Robot.info "loaded Roby #{Roby::VERSION}"
        end

	# Load the controller
	Roby.execute do
	    begin
		controller_file = File.join(APP_DIR, "controllers", "#{app.robot_name}.rb")
		if File.readable?(controller_file)
		    Robot.info "loading controller file #{controller_file}"
		    load controller_file
		end
		Robot.info "done initialization"
	    rescue Interrupt
	    end
	end
    end
rescue Interrupt
    Roby.fatal "interrupted"
end

