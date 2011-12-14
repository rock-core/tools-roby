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
                controller_file = Roby.app.find_files("scripts", "controllers", "ROBOT.rb", :all => false, :order => :specific_first) ||
                    Roby.app.find_files("controllers", "ROBOT.rb", :all => false, :order => :specific_first)
                if controller_file
                    Robot.info "loading controller file #{controller_file}"
                    load controller_file
                    break
                end
		Robot.info "done initialization"
	    rescue Interrupt
	    end
	end
    end
end

