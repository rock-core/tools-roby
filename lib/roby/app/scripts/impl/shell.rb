require File.join(File.dirname(__FILE__), '..', '..', 'config', 'app-run.rb')
app = Roby.app

robot_name = ARGV.shift
app.robot robot_name, (ARGV.shift || robot_name)
require File.join(File.dirname(__FILE__), '..', '..', 'config', 'app-load.rb')
app.setup

require 'irb'
IRB.setup(nil)

control = Roby::ControlInterface.new(Roby.control)
begin
    ws  = IRB::WorkSpace.new(binding)
    irb = IRB::Irb.new(ws)
    IRB.conf[:MAIN_CONTEXT] = irb.context

    trap("SIGINT") do
	irb.signal_handle
    end

    catch(:IRB_EXIT) do
	irb.eval_input
    end
rescue Interrupt
    Roby.control.quit
    Roby.control.join
ensure 
    Roby.control.join
end

