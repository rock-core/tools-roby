# frozen_string_literal: true

require "roby"
require "websocket"
require "roby/interface/base"
require "roby/interface/protocol"
require "roby/interface/job"
require "roby/interface/exceptions"
require "roby/interface/command_argument"
require "roby/interface/command"
require "roby/interface/command_library"
require "roby/interface/interface"
require "roby/interface/channel"
require "roby/interface/server"
require "roby/interface/client"
require "roby/interface/subcommand_client"
require "roby/interface/tcp"
require "roby/interface/shell_client"
require "roby/interface/shell_subcommand"

Roby::Interface::Protocol.register_marshallers(Roby::Interface::Protocol)
