module Roby
    module Actions
        module Models
        # Definition of model-level functionality for StateMachine models
        module StateMachine
            include ExecutionContext

            # The action interface model this state machine model is defined on
            # @return [Model<Interface>,Model<Library>]
            attr_accessor :action_interface
            # The starting state
            # @return [State]
            attr_reader :starting_state

            # The set of defined states
            # @return [Array<State>]
            inherited_attribute(:state, :states) { Array.new }
            # The set of defined transitions, as (State,EventName)=>State
            # @return [Array<(StateEvent,State)>]
            inherited_attribute(:transition, :transitions) { Array.new }
            # The set of defined forwards, as (State,EventName)=>EventName
            # @return [Array<(StateEvent,TaskEvent)>]
            inherited_attribute(:forward, :forwards) { Array.new }
            # A set of actions that should always be active when this state
            # machine is running
            # @return [Set<State>]
            inherited_attribute(:dependency, :dependencies) { Set.new }

            # Creates a new state machine model as a submodel of self
            #
            # @param [Model<Interface>] action_interface the action
            #   interface model on which this state machine is defined
            # @param [Model<Roby::Task>] task_model the
            #   task model that is going to be used as a toplevel task for the
            #   state machine
            # @return [Model<StateMachine>] a subclass of StateMachine
            def new_submodel(action_interface, task_model = Roby::Task, arguments = Array.new)
                submodel = super(task_model, arguments)
                submodel.action_interface = action_interface
                submodel
            end

            # Creates a state from an object
            def state(object, task_model = Roby::Task)
                if object.kind_of?(Actions::Action)
                    state = StateFromAction.new(object)
                    states << state
                    state
                elsif object.respond_to?(:to_action_state)
                    state = object.to_action_state
                    states << state
                    state
                elsif object.respond_to?(:instanciate)
                    state = StateFromInstanciationObject.new(object, task_model)
                    states << state
                    state
                elsif object.kind_of?(Models::ExecutionContext::Variable)
                    state = StateFromVariable.new(object.name, task_model)
                    states << state
                    state
                else raise ArgumentError, "cannot create a state from #{object}"
                end
            end

            def self.validate_state(object)
                if !object.kind_of?(State)
                    raise ArgumentError, "expected a state object, got #{object}. States need to be created from e.g. actions by calling #state before they can be used in the state machine"
                end
                object
            end

            # Declares the starting state
            def start(state)
                @starting_state = Models::StateMachine.validate_state(state)
            end

            # Declares a transition from a state to a new state, caused by an
            # event
            #
            # @overload transition(state.my_event, new_state)
            #   declares that once the 'my' event on the given state is emitted,
            #   we should transition to new_state
            # @overload transition(state, event, new_state)
            #   declares that, while in state 'state', transition to 'new_state'
            #   if the given event is emitted
            #
            def transition(*spec)
                if spec.size == 2
                    state_event, new_state = *spec
                    transition(state_event.task_model, state_event, Models::StateMachine.validate_state(new_state))
                elsif spec.size != 3
                    raise ArgumentError, "expected 2 or 3 arguments, got #{spec.size}"
                else
                    state, state_event, new_state = *spec
                    transitions << [state, state_event, Models::StateMachine.validate_state(new_state)]
                end
            end

            # Declares that the given event on the root task of the state should
            # be forwarded to an event on this task
            #
            # @overload forward(state.my_event, target_event)
            #   declares that, while in state 'state', forward 'my_event' to the
            #   given event name on the state machine task
            # @overload forward(state, event, target_event)
            #   declares that, while in state 'state', forward 'event' to the
            #   given event name on the state machine task
            #
            def forward(*spec)
                if spec.size == 2
                    state_event, target_event = *spec
                    forward(state_event.task_model, state_event, target_event)
                elsif spec.size != 3
                    raise ArgumentError, "expected 2 or 3 arguments, got #{spec.size}"
                else
                    state, event, target_event = *spec
                    forwards << [state, event, target_event.symbol]
                end
            end

            def depends_on(task, options = Hash.new)
                options = Kernel.validate_options options, :role
                task = Models::StateMachine.validate_state(task)
                dependencies << [task, options[:role]]
                task
            end

            # Returns the set of actions that should be active when in state
            # +state+.
            #
            # It includes state itself, as state should run when it is active
            # @return [Set<State>]
            def required_actions_in_state(state)
                result = Hash.new
                state.dependencies.each do |action, role|
                    result[action] ||= Set.new
                    result[action] << role if role
                end
                each_dependency do |action, role|
                    result[action] ||= Set.new
                    result[action] << role if role
                end
                result[state] ||= Set.new
                result[state] << 'current_state'
                result
            end

            # Evaluates a state machine definition block
            def parse(&block)
                instance_eval(&block)
            end

            def method_missing(m, *args, &block)
                if action = action_interface.find_action_by_name(m.to_s)
                    action_interface.send(m, *args, &block)
                else return super
                end
            end
        end
        end
    end
end


