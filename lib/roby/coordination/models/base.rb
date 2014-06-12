module Roby
    module Coordination
        module Models
        # Model part of Base
        module Base
            include MetaRuby::ModelAsClass
            include Arguments

            # Gets or sets the root task model
            #
            # @return [Root] the root task model, i.e. a representation of the
            #   task this execution context is going to be run on
            def root(*new_root)
                if !new_root.empty?
                    @root = Root.new(new_root.first)
                elsif @root then @root
                elsif superclass.respond_to?(:root)
                    superclass.root
                end
            end

            # @deprecated use {#root} instead, as it is a more DSL-like API
            attr_writer :root

            # @return [Model<Roby::Task>] the task model this execution context
            #   is attached to
            def task_model; root.model end

            # Gives direct access to the root's events
            #
            # This is needed to be able to use a coordination model as model for
            # a coordination task, which in turn gives access to e.g. states in
            # an action state machine
            def find_event(name)
                root.find_event(name)
            end

            # Returns a model suitable for typing in {Task}
            #
            # More specifically, it either returns a coordination model if the
            # child is based on one, and the child task model otherwise
            #
            # @return [Model<Coordination::Base>,Model<Roby::Task>]
            def find_child(name)
                subtask = each_task.find { |t| t.name == name }
                if subtask
                    begin return subtask.to_coordination_model
                    rescue ArgumentError
                        subtask.model
                    end
                end
            end

            # Returns the task for the given name, if found, nil otherwise
            #
            # @return Roby::Coordination::Models::TaskFromAction
            def find_task_by_name(name)
                tasks.find do |m|
                    m.name == name.to_s
                end
            end

            # The set of defined tasks
            # @return [Array<Task>]
            inherited_attribute(:task, :tasks) { Array.new }

            # The set of fault response tables that should be active when this
            # coordination model is
            # @return [Array<(FaultResponseTable,Hash)>]
            inherited_attribute(:used_fault_response_table, :used_fault_response_tables) { Array.new }

            # Creates a new execution context model as a submodel of self
            #
            # @param [Model<Roby::Task>] subclass the
            #   task model that is going to be used as a toplevel task for the
            #   state machine
            # @return [Model<StateMachine>] a subclass of StateMachine
            def setup_submodel(subclass, options = Hash.new)
                options = Kernel.validate_options options, :root => Roby::Task
                subclass.root(options[:root])
                super
            end

            # Creates a state from an object
            def task(object, task_model = Roby::Task)
                if object.respond_to?(:to_coordination_task)
                    task = object.to_coordination_task(task_model)
                    tasks << task
                    task
                elsif object.respond_to?(:as_plan)
                    task = TaskFromAsPlan.new(object, task_model)
                    tasks << task
                    task
                else raise ArgumentError, "cannot create a task from #{object}"
                end
            end

            # Assigns names to tasks based on the name of the local variables
            # they are assigned to
            #
            # This must be called by methods that are themselves called during
            # parsing
            #
            # @param [String] suffix that should be added to all the names
            def parse_task_names(suffix)
                definition_context = binding.callers.find { |b| b.frame_type == :block }
                return if !definition_context

                # Assign names to tasks using the local variables
                vars = definition_context.eval "local_variables"
                values = definition_context.eval "[#{vars.map { |n| "#{n}" }.join(", ")}]"
                vars.zip(values).each do |name, object|
                    if object.kind_of?(Task)
                        object.name = "#{name}#{suffix}"
                    end
                end
            end

            def method_missing(m, *args, &block)
                if has_argument?(m)
                    if args.size != 0
                        raise ArgumentError, "expected zero arguments to #{m}, got #{args.size}"
                    end
                    Variable.new(m)
                elsif m.to_s =~ /(.*)_event$/ || m.to_s =~ /(.*)_child$/
                    return root.send(m, *args, &block)
                else return super
                end
            end

            def validate_task(object)
                if !object.kind_of?(Coordination::Models::Task)
                    raise ArgumentError, "expected a state object, got #{object}. States need to be created from e.g. actions by calling #state before they can be used in the state machine"
                end
                object
            end

            def validate_or_create_task(task)
                if !task.kind_of?(Coordination::Models::Task)
                    task(task)
                else task
                end
            end

            def validate_event(object)
                if !object.kind_of?(Coordination::Models::Event)
                    raise ArgumentError, "expected an action-event object, got #{object}. Acceptable events need to be created from e.g. actions by calling #task(action).my_event"
                end
                object
            end

            # Declare that this fault response table should be active as long as
            # this coordination model is
            def use_fault_response_table(table_model, arguments = Hash.new)
                arguments = table_model.validate_arguments(arguments)
                used_fault_response_tables << [table_model, arguments]
            end
        end
        end
    end
end

