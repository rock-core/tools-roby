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

            # The action interface on which this action is defined
            attr_accessor :action_interface_model

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
            # If this action is actually a coordination model, returns it
            #
            # @return [nil,Coordination::Models::Base]
            attr_accessor :coordination_model

            # @return [Action] an action using this action model and the given
            #   arguments
            def new(arguments = Hash.new)
                Actions::Action.new(self, normalize_arguments(arguments))
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

            def initialize(action_interface_model = nil, doc = nil)
                @action_interface_model = action_interface_model
                @doc = doc
                @arguments = []
                @returned_type = Roby::Task
                @advanced = nil
            end

            def initialize_copy(old)
                super
                @arguments = arguments.map(&:dup)
            end
            
            def ==(other)
                other.kind_of?(self.class) &&
                    other.action_interface_model == action_interface_model &&
                    other.name == name
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

            # Instanciate this action on the given plan
            def instanciate(plan, arguments = Hash.new)
                run(action_interface_model.new(plan), arguments)
            end

            # Executes the action on the given action interface
            def run(action_interface, arguments = Hash.new)
                if self.arguments.empty?
                    if !arguments.empty?
                        raise ArgumentError, "#{name} expects no arguments, but #{arguments.size} are given"
                    end
                    result = action_interface.send(name).as_plan
                else
                    default_arguments = self.arguments.inject(Hash.new) do |h, arg|
                        h[arg.name] = arg.default
                        h
                    end
                    arguments = Kernel.validate_options arguments, default_arguments
                    self.arguments.each do |arg|
                        if arg.required && !arguments.has_key?(arg.name.to_sym)
                            raise ArgumentError, "required argument #{arg.name} not given to #{name}"
                        end
                    end
                    result = action_interface.send(name, arguments).as_plan
                end
                # Make the planning task inherit the model/argument flags
                if planning_task = result.planning_task
                    if planning_task.respond_to?(:action_model=)
                        planning_task.action_model ||= self
                    end
                    if planning_task.respond_to?(:action_arguments=)
                        result.planning_task.action_arguments ||= arguments
                    end
                end
                result
            end

            # Create a new action model that is bound to a different interface model
            #
            # @param [Models::Interface] action_interface_model the new model
            # @param [Boolean] force the rebind will happen only if the new
            #   interface model is a submodel of the current one. If force is
            #   true, it will be done regardless.
            # @return [Action] the rebound action model
            def rebind(action_interface_model, force: false)
                m = dup
                # We rebind only if the new interface model is a submodel of the
                # old one
                if force || (action_interface_model <= self.action_interface_model)
                    m.action_interface_model = action_interface_model
                    if coordination_model
                        m.coordination_model = coordination_model.rebind(action_interface_model)
                    end
                end
                m
            end

            # Returns the plan pattern that will deploy this action on the plan
            def plan_pattern(arguments = Hash.new)
                job_id, arguments = Kernel.filter_options arguments, :job_id

                planner = Roby::Actions::Task.new(
                    Hash[action_interface_model: action_interface_model,
                    action_model: self,
                    action_arguments: arguments].merge(job_id))
                planner.planned_task
            end

            def as_plan(arguments = Hash.new)
                plan_pattern(arguments)
            end

            def proxy(peer)
                interface_model = action_interface_model.proxy(peer)
                if interface_model.respond_to?(:find_action_by_name) && (action = interface_model.find_action_by_name(name))
                    return action
                end

                result = self.dup
                result.proxy!(peer, interface_model, arguments)
                result
            end

            def proxy!(peer, interface_model, arguments)
                @action_interface_model = interface_model
                @returned_type = returned_type.proxy(peer)
                @arguments = arguments.proxy(peer)
            end

            def to_s
                if action_interface_model
                    "#{action_interface_model.name}.#{name}"
                else
                    "<anonymous>.#{name}"
                end
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

            # Returns the underlying coordination model
            #
            # @raise [ArgumentError] if this action is not defined by a
            #   coordination model
            # @return [Model<Coordination::Base>]
            def to_coordination_model
                if coordination_model
                    coordination_model
                else raise ArgumentError, "#{self} does not seem to be based on a coordination model"
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

