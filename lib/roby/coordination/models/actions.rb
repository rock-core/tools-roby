module Roby
    module Coordination
        module Models
        # Metamodel for Coordination::Actions
        module Actions
            include Base

            # The action interface model this state machine model is defined on
            # @return [Model<Interface>,Model<Library>]
            attr_accessor :action_interface

            # The set of defined forwards, as (Task,EventName)=>EventName
            # @return [Array<(StateEvent,TaskEvent)>]
            inherited_attribute(:forward, :forwards) { Array.new }

            # A set of tasks that should always be active when this state
            # machine is running
            # @return [Set<Task>]
            inherited_attribute(:dependency, :dependencies) { Set.new }

            # Creates a new state machine model as a submodel of self
            #
            # @param [Model<Coordination::Actions>] submodel the submodel that
            #   is being setup
            # @option options [Model<Actions::Interface>] :action_interface the action
            #   interface model on which this state machine is defined
            # @option options [Model<Roby::Task>] :root the task model that is
            #   going to be used as a toplevel task for the state machine
            def setup_submodel(submodel, options = Hash.new)
                options, super_options = Kernel.filter_options options, :action_interface
                super(submodel, super_options)
                submodel.action_interface = options[:action_interface]
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
                    forward(state_event.task_model, state_event, target_event)
                elsif spec.size != 3
                    raise ArgumentError, "expected 2 or 3 arguments, got #{spec.size}"
                else
                    state, event, target_event = *spec
                    forwards << [state, event, target_event]
                end
            end

            def depends_on(task, options = Hash.new)
                options = Kernel.validate_options options, :role
                task = validate_task(task)
                dependencies << [task, options[:role]]
                task
            end

            # Returns the set of actions that should be active when the given
            # task is active
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

