module Roby
    module Actions
        extend Logger::Hierarchy
    end
end

require 'roby/actions/action_model'
require 'roby/actions/action'
require 'roby/actions/interface_model'
require 'roby/actions/interface'
require 'roby/actions/task'

require 'roby/actions/calculus'
require 'roby/actions/execution_context_model'
require 'roby/actions/execution_context'
require 'roby/actions/state_machine'
require 'roby/actions/library'
