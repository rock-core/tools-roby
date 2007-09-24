require 'roby/distributed/connection_space'
require 'roby/distributed/protocol'

config = Roby.app
config.setup
begin
    config.start_distributed
    sleep
rescue Interrupt
ensure
    config.stop_distributed
end

