require File.join(APP_DIR, 'config', 'init.rb')

# Here, we are supposed to be initialized. Setup the Roby environment itself
RobyInit()




include Roby
control = Control.instance

require 'irb'
IRB.setup(nil)

ws  = IRB::WorkSpace.new(binding)
irb = IRB::Irb.new(ws)
IRB.conf[:MAIN_CONTEXT] = irb.context

trap("SIGINT") do
    irb.signal_handle
end

catch(:IRB_EXIT) do
    irb.eval_input
end

control.quit
control.join

