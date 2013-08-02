module Roby
    module Coordination
        module Models
        # Model part of Base
        module Base
            include MetaRuby::ModelAsClass

            # @return [Root] the root task model, i.e. a representation of the
            #   task this execution context is going to be run on
            def root
                if @root then @root
                elsif superclass.respond_to?(:root)
                    superclass.root
                end
            end

            Argument = Struct.new :name, :required, :default

            attr_writer :root

            # @return [Model<Roby::Task>] the task model this execution context
            #   is attached to
            def task_model; root.model end

            # The set of defined tasks
            # @return [Array<Task>]
            inherited_attribute(:task, :tasks) { Array.new }

            # The set of arguments available to this execution context
            # @return [Array<Symbol>]
            inherited_attribute(:argument, :arguments, :map => true) { Hash.new }

            # Define a new argument for this coordination model
            #
            # Arguments are made available within the coordination model as
            # Variable objects
            #
            # @param [String,Symbol] name the argument name
            # @param [Hash] options
            # @option options :default a default value for this argument. Note
            #   that 'nil' is considered as a proper default value.
            # @return [Argument] the new argument object
            def argument(name, options = Hash.new)
                options = Kernel.validate_options options, :default
                arguments[name.to_sym] = Argument.new(name.to_sym, !options.has_key?(:default), options[:default])
            end

            # Validates that the provided argument hash is valid for this
            # particular coordination model
            #
            # @raise ArgumentError if some given arguments are not known to this
            #   model, or if some required arguments are not set
            def validate_arguments(arguments)
                arguments = Kernel.normalize_options arguments
                arguments.keys.each do |arg_name|
                    if !find_argument(arg_name)
                        raise ArgumentError, "#{arg_name} is not an argument on #{self}"
                    end
                end
                each_argument do |_, arg|
                    if !arguments.has_key?(arg.name)
                        if arg.required
                            raise ArgumentError, "#{arg.name} is required by #{self}, but is not provided (given arguments: #{arguments})"
                        end
                        arguments[arg.name] = arg.default
                    end
                end
                arguments
            end

            # Creates a new execution context model as a submodel of self
            #
            # @param [Model<Roby::Task>] task_model the
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

            def method_missing(m, *args, &block)
                if has_argument?(m)
                    if args.size != 0
                        raise ArgumentError, "expected zero arguments to #{m}, got #{args.size}"
                    end
                    Variable.new(m)
                elsif m.to_s =~ /(.*)_event$/ || m.to_s =~ /(.*)_child/
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

            def validate_event(object)
                if !object.kind_of?(Coordination::Models::Event)
                    raise ArgumentError, "expected an action-event object, got #{object}. Acceptable events need to be created from e.g. actions by calling #task(action).my_event"
                end
                object
            end

        end
        end
    end
end

