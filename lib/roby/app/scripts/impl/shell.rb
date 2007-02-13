require File.join(File.dirname(__FILE__), '..', '..', 'config', 'app-run.rb')
config = Roby::Application.config
config.run do
    control = Control.instance

    require 'irb'
    IRB.setup(nil)

    interface = ControlInterface.new(Control.instance)

    ws  = IRB::WorkSpace.new(binding)
    irb = IRB::Irb.new(ws)
    IRB.conf[:MAIN_CONTEXT] = irb.context

    trap("SIGINT") do
	irb.signal_handle
    end

    catch(:IRB_EXIT) do
	irb.eval_input
    end
end
