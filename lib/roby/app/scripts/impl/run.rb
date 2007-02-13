require File.join(File.dirname(__FILE__), '..', '..', 'config', 'app-run.rb')
config = Roby::Application.config
config.run do
    # Load the controller
    include Roby
    begin
	load File.join(APP_DIR, "controllers", "#{config.robot_name}.rb")
    rescue Interrupt
    end
end

