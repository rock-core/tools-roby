module Roby
    module Actions
        module Models
        # Model part of ExecutionContext
        module ExecutionContext
            include MetaRuby::ModelAsClass

            # @return [Root] the root task model, i.e. a representation of the
            #   task this execution context is going to be run on
            def root
                if @root then @root
                elsif superclass.respond_to?(:root)
                    superclass.root
                end
            end

            attr_writer :root

            # @return [Model<Roby::Task>] the task model this execution context
            #   is attached to
            def task_model; root.model end

            # The set of defined tasks
            # @return [Array<Task>]
            inherited_attribute(:task, :tasks) { Array.new }

            # The set of arguments available to this execution context
            # @return [Array<Symbol>]
            inherited_attribute(:argument, :arguments) { Array.new }

            # Creates a new execution context model as a submodel of self
            #
            # @param [Model<Roby::Task>] task_model the
            #   task model that is going to be used as a toplevel task for the
            #   state machine
            # @return [Model<StateMachine>] a subclass of StateMachine
            def new_submodel(task_model = Roby::Task, arguments = Array.new)
                submodel = super()
                submodel.root = Root.new(task_model)
                submodel.arguments.concat(arguments.map(&:to_sym).to_a)
                submodel
            end

            # Returns an object that can be used to refer to an event of the
            # toplevel task on which this state machine model applies
            def find_event(event_name)
                root.find_event(event_name)
            end

            # Returns an object that can be used to refer to the children of
            # this task from within the execution context
            def find_child(child_name, child_model = nil)
                root.find_child(child_name, child_model)
            end

            # Returns true if this is the name of an argument for this state
            # machine model
            def has_argument?(name)
                each_argument.any? { |n| n == name }
            end

            # Creates a state from an object
            def task(object, task_model = Roby::Task)
                if object.respond_to?(:to_coordination_task)
                    task = object.to_coordination_task(task_model)
                    tasks << task
                    task
                elsif object.respond_to?(:as_plan)
                    task = ActionCoordination::TaskFromAsPlan.new(object, task_model)
                    tasks << task
                    task
                else raise ArgumentError, "cannot create a task from #{object}"
                end
            end

            def method_missing(m, *args, &block)
                if has_argument?(m)
                    if args.size != 0
                        raise ArgumentError, "expected zero arguments to #{m}, got #{args.size}"
                    end
                    Variable.new(m)
                elsif m.to_s =~ /(.*)_event$/
                    find_event($1)
                elsif m.to_s =~ /(.*)_child$/
                    find_child($1)
                else return super
                end
            end

            def validate_task(object)
                if !object.kind_of?(ExecutionContext::Task)
                    raise ArgumentError, "expected a state object, got #{object}. States need to be created from e.g. actions by calling #state before they can be used in the state machine"
                end
                object
            end

            def validate_event(object)
                if !object.kind_of?(ExecutionContext::Event)
                    raise ArgumentError, "expected an action-event object, got #{object}. Acceptable events need to be created from e.g. actions by calling #task(action).my_event"
                end
                object
            end

        end
        end
    end
end

