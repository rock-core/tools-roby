module Roby
    module Coordination
        module Models
        # Metamodel for Coordination::Actions
        module Actions
            include Base

            attribute(:captures) { Hash.new }

            # The action interface model this state machine model is defined on
            # @return [Actions::Models::Interface,Actions::Models::Library]
            attr_accessor :action_interface

            # Create a new coordination model based on a different action
            # interface
            def rebind(action_interface)
                m = dup
                m.action_interface = action_interface

                task_mapping = Hash.new
                task_mapping[root] = root.rebind(m)
                tasks.each do |task|
                    task_mapping[task] = task.rebind(m)
                end
                m.map_tasks(task_mapping)
                m
            end

            # (see Base#map_tasks)
            def map_tasks(mapping)
                super

                @forwards = forwards.map do |state, event, target_event|
                    state = mapping[state]
                    event = mapping[event.task].find_event(event.symbol)
                    target_event = mapping[target_event.task].find_event(target_event.symbol)
                    [state, event, target_event]
                end

                @dependencies = dependencies.map do |task, role|
                    [mapping[task], role]
                end

                @captures = captures.map_value do |capture, (state, event)|
                    [mapping[state], mapping[event.task].find_event(event.symbol)]
                end
            end

            # The set of defined forwards
            #
            # @return [Array<(Task,Event,Event)>]
            inherited_attribute(:forward, :forwards) { Array.new }

            # A set of tasks that should always be active when self is active
            #
            # @return [Set<Task>]
            inherited_attribute(:dependency, :dependencies) { Set.new }

            # A list of variables that allow to capture event contexts
            inherited_attribute(:capture, :captures) { Hash.new }

            # Creates a new state machine model as a submodel of self
            #
            # @param [Model<Coordination::Actions>] submodel the submodel that
            #   is being setup
            # @option options [Model<Actions::Interface>] :action_interface the action
            #   interface model on which this state machine is defined
            # @option options [Model<Roby::Task>] :root the task model that is
            #   going to be used as a toplevel task for the state machine
            def setup_submodel(submodel, action_interface: nil, **super_options)
                super(submodel, **super_options)
                submodel.action_interface = action_interface
                submodel
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
                    forward(state_event.task, state_event, target_event)
                elsif spec.size != 3
                    raise ArgumentError, "expected 2 or 3 arguments, got #{spec.size}"
                else
                    state, event, target_event = *spec
                    if !toplevel_state?(state)
                        raise NotToplevelState, "cannot specify #{state} as the state to forward from as it is not a toplevel state"
                    elsif !event_active_in_state?(event, state)
                        raise EventNotActiveInState, "cannot forward from #{event} while in state #{state} as the event is not active in this state"
                    elsif !root_event?(target_event)
                        raise NotRootEvent, "can only forward to a root event"
                    end

                    forwards << [state, event, target_event]
                end
            end

            # @api private
            #
            # Raise if the given state is not a toplevel state
            def toplevel_state?(state)
                true
            end

            # @api private
            #
            # Raise if an event is not "active" while in a particular state
            def event_active_in_state?(event, state)
                required_tasks_for(state).has_key?(event.task)
            end

            # @api private
            #
            # Raises if the event is not an event of the root task
            def root_event?(event)
                event.task == root
            end

            # Adds a toplevel dependency
            #
            # This declares that the given task should always run while self is
            # running
            #
            # @param [Task] task
            # @return [Task] the task itself
            def depends_on(task, role: nil)
                task = validate_task(task)
                dependencies << [task, role]
                task
            end

            # Returns the set of actions that should be active when the given
            # task is active, as a mapping from the {Task} object to the roles
            # that this object has (as "dependency roles")
            #
            # It includes task itself, as task should run when it is active
            # @return [{Task=>Set<String>}]
            def required_tasks_for(task)
                result = Hash.new
                task.dependencies.each do |action, role|
                    result[action] ||= Set.new
                    result[action] << role if role
                end
                each_dependency do |action, role|
                    result[action] ||= Set.new
                    result[action] << role if role
                end
                result[task] ||= Set.new
                result[task] << 'current_task'
                result
            end

            # Helper to build delayed arguments
            def from(object)
                Roby::Task.from(object)
            end

            # Helper to build delayed arguments
            def from_state(state_object = State)
                Roby::Task.from_state(state_object)
            end

            # Evaluates a state machine definition block
            def parse(&block)
                class_eval(&block)
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

