require 'roby'
module Roby
    # Implementation of a job-oriented interface for Roby controllers
    #
    # This is the implementation of e.g. the Roby shell
    module Interface
        extend Logger::Hierarchy
    end
end

require 'websocket'
require 'utilrb/hash'
require 'roby/interface/job'
require 'roby/interface/exceptions'
require 'roby/interface/command_argument'
require 'roby/interface/command'
require 'roby/interface/command_library'
require 'roby/interface/interface'
require 'roby/interface/droby_channel'
require 'roby/interface/server'
require 'roby/interface/client'
require 'roby/interface/tcp'
require 'roby/interface/shell_client'
require 'roby/interface/shell_subcommand'
