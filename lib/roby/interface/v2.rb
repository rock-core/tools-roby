# frozen_string_literal: true

require "roby/interface/core"

module Roby
    module Interface
        # V2 of the remote Roby control protocol
        module V2
            extend Logger::Hierarchy

            DEFAULT_PORT = Roby::Interface::DEFAULT_PORT_V2
        end
    end
end

require "websocket"
require "roby/interface/v2/protocol"
require "roby/interface/v2/channel"
require "roby/interface/v2/server"
require "roby/interface/v2/client"
require "roby/interface/v2/subcommand_client"
require "roby/interface/v2/tcp"
require "roby/interface/v2/shell_client"
require "roby/interface/v2/shell_subcommand"

Roby::Interface::V2::Protocol
    .register_marshallers(Roby::Interface::V2::Protocol)
