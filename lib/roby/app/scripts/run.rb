require File.join(File.dirname(__FILE__), '..', 'run')
app = Roby.app

robot_name = ARGV.shift
app.robot robot_name, (ARGV.shift || robot_name)
require File.join(File.dirname(__FILE__), '..', 'load')
app.setup
app.run do
    # Load the controller
    include Roby
    begin
	load File.join(APP_DIR, "controllers", "#{app.robot_name}.rb")
    rescue Interrupt
    end
end

