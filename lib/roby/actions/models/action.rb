module Roby
    module Actions
        module Models
        # Basic description of an action
        class Action
            # Structure that stores the information about planning method arguments
            #
            # See MethodDescription
            Argument = Struct.new :name, :doc, :required, :default do
                def pretty_print(pp)
                    pp.text "#{name}: #{doc}"
                    if required then pp.text ' (required)'
                    else pp.text ' (optional)'
                    end
                    if default
                        pp.text " default=#{default}"
                    end
                end

                def required?
                    !!required
                end
            end

            # The action name
            attr_accessor :name
            # The action description
            attr_accessor :doc
            # The description of the action arguments
            #
            # @return [Array<Argument>]
            attr_reader :arguments
            # If true, the method is flagged as advanced. I.e., it won't be
            # listed by default in the shell when the 'actions' command is
            # called
            attr_predicate :advanced?, true
            # The return type for this method, as a task or task service model.
            # It is Roby::Task by default
            #
            # @return [Model<Roby::Task>,Model<Roby::TaskService>]
            attr_reader :returned_type

            # @return [Action] an action using this action model and the given
            #   arguments
            def new(**arguments)
                Actions::Action.new(self, normalize_arguments(arguments))
            end

            def ==(other)
                other.kind_of?(self.class) &&
                    other.name == name &&
                    other.arguments == arguments &&
                    other.returned_type == returned_type
            end


            # Task model that can be used to represent this action in a plan
            def returned_task_type
                if @returned_task_type
                    return @returned_task_type
                end

                if returned_type.kind_of?(Roby::Models::TaskServiceModel)
                    model = Class.new(Roby::Task)
                    model.provides m.returned_type
                    @returned_task_type = model
                else
                    # Create an abstract task which will be planned
                    @returned_task_type = returned_type
                end
            end

            def initialize(doc = nil)
                if doc.kind_of?(Action)
                    @name = doc.name
                    @doc = doc.doc
                    @arguments = doc.arguments.map(&:dup)
                    @returned_type = doc.returned_type
                    @advanced = doc.advanced?
                else
                    @name = nil
                    @doc = doc
                    @arguments = []
                    @returned_type = Roby::Task
                    @advanced = false
                end
            end

            def initialize_copy(old)
                super
                @arguments = arguments.map(&:dup)
            end

            # @api private
            #
            # Validates that the information provided in the argument can safely
            # be used to update self
            #
            # @raise [ArgumentError]
            def validate_can_overload(parent)
                overloaded_return  = parent.returned_type
                overloading_return = self.returned_type

                if !overloading_return.fullfills?(overloaded_return)
                    if overloading_return.kind_of?(Class)
                        raise ArgumentError, "overloading return type #{overloading_return} does not fullfill #{overloaded_return}, cannot merge the action models"
                    elsif overloaded_return != Roby::Task
                        raise ArgumentError, "overloading return type #{overloading_return} is a service model which does not fullfill #{overloaded_return}, and Roby does not support return type specifications that are composite of services and tasks"
                    end
                end
            end

            # Update this action model with information from another, to reflect
            # that self overloads the other model
            #
            # @param [Action] parent the action model that is being overloaded
            # @raise [ArgumentError] if the actions return types are not
            #   compatible
            def overloads(parent)
                validate_can_overload(parent)

                self.doc ||= parent.doc
                @arguments.concat(parent.arguments.find_all { |a| !has_arg?(a.name) })
            end

            # Documents a new required argument to the method
            def required_arg(name, doc = nil)
                arguments << Argument.new(name.to_s, doc, true)
                self
            end

            # Documents a new optional argument to the method
            def optional_arg(name, doc = nil, default = nil)
                arg = Argument.new(name.to_s, doc, false)
                arg.default = default
                arguments << arg
                self
            end

            # Return true if this action has at least one required argument
            def has_required_arg?
                arguments.any?(&:required?)
            end

            # Return true if a argument with the given name is specified
            def has_arg?(name)
                !!find_arg(name)
            end

            # Find the argument from its name
            #
            # @param [String] name the argument name
            # @return [Argument,nil]
            def find_arg(name)
                name = name.to_s
                arguments.find { |arg| arg.name == name }
            end

            # Enumerate this action's arguments
            #
            # @yieldparam [Argument] arg
            def each_arg(&block)
                arguments.each(&block)
            end

            # Sets the advanced flag to true. See #advanced?
            def advanced
                @advanced = true 
                self
            end

            # Sets the type of task returned by the action
            def returns(type)
                if !type.kind_of?(Class) && !type.kind_of?(Roby::Models::TaskServiceModel)
                    raise ArgumentError, "#{type} is neither a task model nor a task service model"
                elsif type.kind_of?(Class) && !(type <= Roby::Task)
                    raise ArgumentError, "#{type} is neither a task model nor a task service model"
                end
                @returned_type = type
                self
            end

            def normalize_arguments(arguments)
                Kernel.validate_options arguments, self.arguments.map(&:name)
            end

            def as_plan(**arguments)
                plan_pattern(**arguments)
            end

            def pretty_print(pp)
                pp.text "Action #{to_s}"
                pp.nest(2) do
                    pp.breakable
                    pp.text "Returns "
                    returned_type.pretty_print(pp)
                    pp.breakable
                    if arguments.empty?
                        pp.text "No arguments."
                    else
                        pp.text "Arguments:"
                        pp.nest(2) do
                            pp.seplist(arguments.sort_by(&:name)) do |arg|
                                arg.pretty_print(pp)
                            end
                        end
                    end
                end
            end

            def to_action_model
                self
            end

            def to_action
                new
            end
        end
        end
    end
end

