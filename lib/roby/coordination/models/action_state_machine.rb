# frozen_string_literal: true

module Roby
    module Coordination
        module Models
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
            #
            # Action state machine models are usually created through an action
            # interface with Interface#action_state_machine. The state machine
            # model can then be retrieved using
            # {Actions::Models::Action#coordination_model}.
            #
            # @example creating an action state machine model
            #   class Main < Roby::Actions::Interface
            #     action_state_machine 'example_action' do
            #       move  = state move(speed: 0.1)
            #       stand = state move(speed: 0)
            #       # This monitor triggers each time the system moves more than
            #       # 0.1 meters
            #       d_monitor = task monitor_movement_threshold(d: 0.1)
            #       # This monitor triggers after 20 seconds
            #       t_monitor = task monitor_time_threshold(t: 20)
            #       # Make the distance monitor run in the move state
            #       move.depends_on d_monitor
            #       # Make the time monitor run in the stand state
            #       stand.depends_on t_monitor
            #       start move
            #       transition move, d_monitor.success_event, stand
            #       transition stand, t_monitor.success_event, move
            #     end
            #   end
            #
            # @example retrieving a state machine model from an action
            #   Main.find_action_by_name('example_action').coordination_model
            module ActionStateMachine
                include Actions

                # The starting state
                # @return [Task]
                attr_reader :starting_state

                # The set of defined transitions
                #
                # @return [Array<(Task,Event,Task)>]
                inherited_attribute(:transition, :transitions) { [] }

                # (see Actions#toplevel_state?)
                def toplevel_state?(state)
                    root == state ||
                        starting_state == state ||
                        transitions.any? { |from_state, _, to_state| from_state == state || to_state == state }
                end

                # @see (Base#map_task)
                def map_tasks(mapping)
                    super

                    @starting_state = mapping[starting_state]
                    @transitions = transitions.map do |state, event, new_state|
                        [mapping[state],
                         mapping[event.task].find_event(event.symbol),
                         mapping[new_state]]
                    end
                end

                def parse_names
                    super(Task => "_state", Capture => "")
                end

                # Declares the starting state
                def start(state)
                    parse_names
                    if @starting_state
                        raise ArgumentError, "this state machine already has a starting "\
                            "state, use #depends_on to run more than one task at startup"
                    end
                    @starting_state = validate_task(state)
                end

                def state(object, task_model = Roby::Task)
                    task(object, task_model)
                end

                # Capture the value of an event context
                #
                # The value returned by #capture is meant to be used as arguments to
                # other states. This is a mechanism to pass information from one
                # state to the next.
                #
                # @example determine the current heading and servo on it
                #   measure_heading = state(self.measure_heading)
                #   start(measure_heading)
                #   current_heading = capture(measure_heading.success_event)
                #   transition measure_heading.success_event, keep_heading(heading: current_heading)
                #
                def capture(state, event = nil, &block)
                    if !event
                        state, event = state.task, state
                    end

                    if !toplevel_state?(state)
                        raise ArgumentError, "#{state} is not a toplevel state, a capture's state must be toplevel"
                    elsif !event_active_in_state?(event, state)
                        raise ArgumentError, "#{event} is not an event that is active in state #{state}"
                    end

                    filter =
                        if block
                            lambda(&block)
                        else
                            ->(ev) { ev.context.first }
                        end

                    capture = Capture.new(filter)
                    captures[capture] = [state, event]
                    capture
                end

                # Returns the state for the given name, if found, nil otherwise
                #
                # @return Roby::Coordination::Models::TaskFromAction
                def find_state_by_name(name)
                    find_task_by_name("#{name}_state")
                end

                def validate_task(object)
                    if !object.kind_of?(Coordination::Models::Task)
                        raise ArgumentError,
                              "expected a state object, got #{object}. States need "\
                              "to be created from e.g. actions by calling #state "\
                              "before they can be used in the state machine"
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
                        raise UnreachableStateUsed.new(unreachable),
                              "#{unreachable.size} states are used in transitions "\
                              "but are actually not reachable"
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
                    parse_names

                    if spec.size == 2
                        state_event, new_state = *spec
                        transition(state_event.task, state_event, new_state)
                    elsif spec.size != 3
                        raise ArgumentError, "expected 2 or 3 arguments, got #{spec.size}"
                    else
                        state, state_event, new_state = *spec
                        validate_task(state)
                        validate_task(new_state)
                        if !event_active_in_state?(state_event, state)
                            raise EventNotActiveInState,
                                  "cannot transition on #{state_event} while in "\
                                  "state #{state} as the event is not active "\
                                  "in this state"
                        end

                        transitions << [state, state_event, new_state]
                    end
                end

                def to_s
                    "#{action_interface}.#{name}"
                end
            end
        end
    end
end
