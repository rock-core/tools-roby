module Roby
    module Actions
        module Models
        # Metamodel for Actions::ActionCoordination
        module ActionCoordination
            include ExecutionContext

            # The action interface model this state machine model is defined on
            # @return [Model<Interface>,Model<Library>]
            attr_accessor :action_interface

            # The set of defined tasks
            # @return [Array<Task>]
            inherited_attribute(:task, :tasks) { Array.new }

            # The set of defined forwards, as (Task,EventName)=>EventName
            # @return [Array<(StateEvent,TaskEvent)>]
            inherited_attribute(:forward, :forwards) { Array.new }

            # A set of tasks that should always be active when this state
            # machine is running
            # @return [Set<Task>]
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

            def validate_task(object)
                if !object.kind_of?(ExecutionContext::Task)
                    raise ArgumentError, "expected a state object, got #{object}. States need to be created from e.g. actions by calling #state before they can be used in the state machine"
                end
                object
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
                instance_eval(&block)
            end

            def method_missing(m, *args, &block)
                if action = action_interface.find_action_by_name(m.to_s)
                    action_interface.send(m, *args, &block)
                else return super
                end
            end

            # Creates a state from an object
            def task(object, task_model = Roby::Task)
                if object.kind_of?(Actions::Action)
                    task = TaskFromAction.new(object)
                    tasks << task
                    task
                elsif object.respond_to?(:to_action_task)
                    task = object.to_action_task
                    tasks << task
                    task
                elsif object.respond_to?(:instanciate)
                    task = TaskFromInstanciationObject.new(object, task_model)
                    tasks << task
                    task
                elsif object.kind_of?(Models::ExecutionContext::Variable)
                    task = TaskFromVariable.new(object.name, task_model)
                    tasks << task
                    task
                else raise ArgumentError, "cannot create a task from #{object}"
                end
            end
        end
        end
    end
end

