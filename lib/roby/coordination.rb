module Roby
    # Namespace for high-level coordination models
    #
    # The existing coordination models are:
    # * Coordination::ActionScript, usually accessed from the #action_script
    #   stanza in an action interface, defines step-by-step list of instructions
    #   where each instruction deals with an action (i.e. start, execute, ...)
    #   and transition are events
    # * Coordination::ActionStateMachine, usually accessed from the #action_state_machine
    #   stanza in an action interface, defines state machines where each state
    #   is realized by a single action, and transition are events
    # * Coordination::TaskScript, usually accessed from the #task_script stanza
    #   in a Roby task model, defines step-by-step list of instructions where each
    #   instruction deals with code blocks and transition are events
    # * Coordination::TaskStateMachine, usually accessed from the
    #   #task_state_machine stanza in a task model, defines state machines where each state
    #   is realized by a code block, and transition are events
    module Coordination
    end
end

require 'binding_of_caller'
require 'roby/coordination/calculus'
require 'roby/coordination/models/task'
require 'roby/coordination/models/event'
require 'roby/coordination/models/root'
require 'roby/coordination/models/variable'
require 'roby/coordination/models/child'
require 'roby/coordination/models/arguments'
require 'roby/coordination/models/base'
require 'roby/coordination/models/task_with_dependencies'
require 'roby/coordination/models/task_from_instanciation_object'
require 'roby/coordination/models/task_from_action'
require 'roby/coordination/models/task_from_variable'
require 'roby/coordination/models/task_from_as_plan'
require 'roby/coordination/models/actions'
require 'roby/coordination/models/action_state_machine'
require 'roby/coordination/script_instruction'
require 'roby/coordination/models/script'
require 'roby/coordination/models/action_script'
require 'roby/coordination/models/fault_handler'
require 'roby/coordination/models/fault_response_table'

require 'roby/coordination/base'
require 'roby/coordination/task_base'
require 'roby/coordination/task'
require 'roby/coordination/event'
require 'roby/coordination/child'
require 'roby/coordination/script'

require 'roby/coordination/actions'
require 'roby/coordination/action_state_machine'
require 'roby/coordination/action_script'
require 'roby/coordination/task_script'
require 'roby/coordination/task_state_machine'
require 'roby/coordination/fault_handling_task'
require 'roby/coordination/fault_handler'
require 'roby/coordination/fault_response_table'
