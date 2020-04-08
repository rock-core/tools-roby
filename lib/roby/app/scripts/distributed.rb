# frozen_string_literal: true

require "roby/distributed"

config = Roby.app
config.setup
begin
    config.start_distributed
    sleep
rescue Interrupt
ensure
    config.stop_distributed
end
