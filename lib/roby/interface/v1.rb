# frozen_string_literal: true

require "roby/interface/core"

module Roby
    module Interface
        # V1 of the remote Roby control protocol
        module V1
            extend Logger::Hierarchy
        end
    end
end

require "websocket"
require "roby/interface/v1/droby_channel"
require "roby/interface/v1/server"
require "roby/interface/v1/client"
require "roby/interface/v1/subcommand_client"
require "roby/interface/v1/tcp"
require "roby/interface/v1/shell_client"
require "roby/interface/v1/shell_subcommand"
