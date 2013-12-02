module Roby
    module Coordination
        module Models

            # Exception raised in state machine definitions when a state is used
            # in a transition, that cannot be reached in the first place
            class UnreachableStateUsed < RuntimeError
                # The set of unreachable states
                attr_reader :states

                def initialize(states)
                    @states = states
                end

                def pretty_print(pp)
                    pp.text "#{states.size} states are unreachable but used in transitions anyways"
                    pp.nest(2) do
                        pp.seplist(states) do |s|
                            pp.breakable
                            s.pretty_print(pp)
                        end
                    end
                end
            end

        # Definition of model-level functionality for action state machines
        #
        # In an action state machine, each state is represented by a single Roby
        # task. At the model level, they get represented by a {Task} object, and
        # more specifically very often by a {TaskFromAction} object. One
        # important bit to understand is that a given Task object represents
        # always the same state (i.e. task0 == task1 if task0 and task1
        # represent the same state). It is for instance possible that task0 !=
        # task1 even if task0 and task1 are issued by the same action.
        #
        # Transitions are stored as ({Task},{Event},{Task}) triplets, specifying
        # the origin state, the triggering event and the target state.
        # {Event#task} is often the same than the origin state, but not
        # always (see below)
        #
        # Note that because some states are subclasses of
        # {TaskWithDependencies}, it is possible that some {Task} objects
        # are not states, only tasks that are dependencies of other states
        # created with {TaskWithDependencies#depends_on} or dependencies of
        # the state machine itself created with {Actions#depends_on}. The events
        # of these task objects can be used in transitions
        module ActionStateMachine
            include Actions

            # The starting state
            # @return [Task]
            attr_reader :starting_state

            # The set of defined transitions
            #
            # @return [Array<(Task,Event,Task)>]
            inherited_attribute(:transition, :transitions) { Array.new }

            # Declares the starting state
            def start(state)
                parse_task_names '_state'
                @starting_state = validate_task(state)
            end

            def state(object, task_model = Roby::Task)
                task(object, task_model)
            end

            def validate_task(object)
                if !object.kind_of?(Coordination::Models::Task)
                    raise ArgumentError, "expected a state object, got #{object}. States need to be created from e.g. actions by calling #state before they can be used in the state machine"
                end
                object
            end

            # Computes the set of states that are used in the transitions but
            # are actually not reachable
            #
            # @return [Array<Task>]
            def compute_unreachable_states
                queue = [starting_state].to_set
                transitions = self.each_transition.to_a.dup

                done_something = true
                while done_something
                    done_something = false
                    transitions.delete_if do |from, _, to|
                        if queue.include?(from)
                            queue << to
                            done_something = true
                        end
                    end
                end

                transitions.map(&:first).to_set
            end

            # Overloaded from Actions to validate the state machine definition
            #
            # @raise [UnreachableStateUsed] if some transitions are using events
            #   from states that cannot be reached from the start state
            def parse(&block)
                super

                if !starting_state
                    raise ArgumentError, "no starting state defined"
                end

                # Validate that all source states in transitions are reachable
                # from the start state
                unreachable = compute_unreachable_states
                if !unreachable.empty?
                    raise UnreachableStateUsed.new(unreachable), "#{unreachable.size} states are used in transitions but are actually not reachable"
                end
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
                parse_task_names '_state'

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


