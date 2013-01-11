module Roby
    module Actions
        # Basic description of an action
        class ActionModel
            # Structure that stores the information about planning method arguments
            #
            # See MethodDescription
            Argument = Struct.new :name, :doc, :required

            # The action interface on which this action is defined
            attr_reader :action_interface_model

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
            attr_predicate :advanced?
            # The return type for this method, as a task or task service model.
            # It is Roby::Task by default
            #
            # @return [Roby::Task]
            attr_reader :returned_type

            def initialize(action_interface_model = nil, doc = nil)
                @action_interface_model = action_interface_model
                @doc = doc
                @arguments = []
                @returned_type = Roby::Task
            end

            # Documents a new required argument to the method
            def required_arg(name, doc = nil)
                arguments << Argument.new(name, doc, true)
                self
            end
            # Documents a new optional argument to the method
            def optional_arg(name, doc = nil)
                arguments << Argument.new(name, doc, false)
                self
            end
            # Sets the advanced flag to true. See #advanced?
            def advanced
                @advanced = true 
                self
            end
            # Sets the type of task returned by the action
            def returns(type)
                if !type.kind_of?(Class) && !type.kind_of?(TaskService)
                    raise ArgumentError, "#{type} is neither a task model nor a task service model"
                elsif type.kind_of?(Class) && !(type <= Roby::Task)
                    raise ArgumentError, "#{type} is neither a task model nor a task service model"
                end
                @returned_type = type
                self
            end

            # Instanciate this action on the given plan
            def instanciate(plan, arguments)
                run(action_interface_model.new(plan), arguments)
            end

            # Executes the action on the given action interface
            def run(action_interface, arguments)
                if self.arguments.empty?
                    action_interface.send(name)
                else
                    action_interface.send(name, arguments)
                end
            end
        end
    end
end


