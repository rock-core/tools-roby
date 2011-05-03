require File.join(File.dirname(__FILE__), '..', 'run')
app = Roby.app

robot_name = ARGV.shift
app.robot robot_name, (ARGV.shift || robot_name)
Roby.display_exception do
    app.setup
    app.run do
        if defined? RUBY_DESCRIPTION
            Robot.info "loaded Roby #{Roby::VERSION} on #{RUBY_DESCRIPTION}"
        else
            Robot.info "loaded Roby #{Roby::VERSION}"
        end

	# Load the controller
	Roby.execute do
	    begin
		controller_files = [app.robot_name, app.robot_type]
                controller_files.each do |name|
                    controller_file = File.join(APP_DIR, "controllers", "#{name}.rb")
                    if File.readable?(controller_file)
                        Robot.info "loading controller file #{controller_file}"
                        load controller_file
                        break
                    end
                end
		Robot.info "done initialization"
	    rescue Interrupt
	    end
	end
    end
end

