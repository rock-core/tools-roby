require File.join(File.dirname(__FILE__), '..', 'run')
app = Roby.app

robot_name = ARGV.shift
app.robot robot_name, (ARGV.shift || robot_name)
require File.join(File.dirname(__FILE__), '..', 'load')
app.setup

require 'irb'
IRB.setup(nil)

control = Roby::Interface.new(Roby.control)
begin
    # Make control the top-level object
    bind = control.instance_eval { binding }
    ws  = IRB::WorkSpace.new(bind)
    irb = IRB::Irb.new(ws)
    IRB.conf[:MAIN_CONTEXT] = irb.context

    trap("SIGINT") do
	irb.signal_handle
    end

    app.run do
	Roby.execute do
	    load File.join(APP_DIR, "controllers", "#{app.robot_name}.rb")
	end
	catch(:IRB_EXIT) do
	    irb.eval_input
	end
    end

rescue Interrupt
    Roby.control.quit
    Roby.control.join
ensure 
    Roby.control.join
end

