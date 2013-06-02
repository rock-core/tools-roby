module Roby
    module Actions
        module Models
        # Definition of model-level functionality for StateMachine models
        module StateMachine
            include ActionCoordination

            # The starting state
            # @return [State]
            attr_reader :starting_state

            # The set of defined transitions, as (State,EventName)=>State
            # @return [Array<(StateEvent,State)>]
            inherited_attribute(:transition, :transitions) { Array.new }

            # Declares the starting state
            def start(state)
                @starting_state = validate_task(state)
            end

            def state(object, task_model = Roby::Task)
                task(object, task_model)
            end

            def validate_task(object)
                if !object.kind_of?(ExecutionContext::Task)
                    raise ArgumentError, "expected a state object, got #{object}. States need to be created from e.g. actions by calling #state before they can be used in the state machine"
                end
                object
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
                    transition(state_event.task_model, state_event, validate_task(new_state))
                elsif spec.size != 3
                    raise ArgumentError, "expected 2 or 3 arguments, got #{spec.size}"
                else
                    state, state_event, new_state = *spec
                    transitions << [state, state_event, validate_task(new_state)]
                end
            end
        end
        end
    end
end


