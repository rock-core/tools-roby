require File.join(File.dirname(__FILE__), '..', '..', 'config', 'app-load.rb')
require 'roby/distributed/connection_space'
require 'roby/distributed/protocol'

config = Roby::Application.config
if !config.loaded_component?('distributed')
    STDERR.puts "dRoby is not loaded"
    exit
end

begin
    config.start_distributed
    sleep
rescue Interrupt
ensure
    config.stop_distributed
end

