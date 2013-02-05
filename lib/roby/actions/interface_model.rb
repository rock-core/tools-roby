module Roby
    module Actions
        module InterfaceModel
            include Utilrb::Models::Registration
	    include Distributed::DRobyModel::Dump

            def promote_registered_action(name, action)
                actions[name] ||= action.rebind(self)
            end

            # The set of actions defined on this interface
            #
            # @returns [Hash<String,ActionModel>]
            # @key_name action_name
            define_inherited_enumerable(:registered_action, :actions, :map => true) { Hash.new }

            # Exception raised when an action is defined with the wrong count of
            # argument (zero if no arguments are specified and one if arguments
            # are specified)
            class ArgumentCountMismatch < ScriptError; end

            # Adds all actions defined in this library in this interface
            def use_library(library)
                include library
            end

            # Enumerates the actions registered on this interface
            #
            # @yieldparam [ActionModel] action
            def each_action
                return enum_for(:each_action) if !block_given?
                each_registered_action do |_, description|
                    yield(description)
                end
            end

            # Clears everything stored on this model
            def clear_model
                super if defined? super
                actions.clear
            end

            # Create a new action description that is going to be used to
            # describe the next method. Note that only methods that have a
            # description are exported as actions
            def describe(doc = nil)
                if @current_description
                    Interface.warn "#{@current_description} started but never used. Did you forget to add a method to your action interface ?"
                end
                @current_description = ActionModel.new(self, doc)
            end

            # Registers a new action on this model
            #
            # If no specific return type has been specified, one is created
            # automatically and registered as a constant on this action
            # interface. For instance, the start_all_devices action would create
            # a simple StartAllDevices task model.
            def register_action(name, action_model)
                if action_model.returned_type == Roby::Task
                    task_model_name = name.camelcase(:upper)
                    if const_defined_here?(task_model_name)
                        action_model.returns(const_get(task_model_name))
                    else
                        task_model = Class.new(Roby::Task) do
                            terminates
                        end
                        const_set task_model_name, task_model
                        action_model.returns(task_model)
                    end
                end

                action_model.name = name
                actions[action_model.name] = action_model
            end

            # Hook used to export methods for which there is a description
            def method_added(method_name)
                super
                if @current_description
                    name = method_name.to_s
                    description, @current_description = @current_description, nil

                    expected_argument_count =
                        if description.arguments.empty? then 0
                        else 1
                        end
                    begin
                        check_arity(instance_method(name), expected_argument_count)
                    rescue ArgumentError
                        if expected_argument_count == 0
                            raise ArgumentCountMismatch, "action #{name} has been declared to have arguments, the #{name} method must be callable with a single Hash argument"
                        else
                            raise ArgumentCountMismatch, "action #{name} has been declared to have no arguments, the #{name} method must be callable without any arguments"
                        end
                    end
                    register_action(name, description)
                end
            end

            # Returns the action description for the given action name, or nil
            # if there are none with that name
            #
            # @param [String] name
            # @returns [ActionModel,nil]
            def find_action_by_name(name)
                find_registered_action(name.to_s)
            end

            # Returns all the action description for the actions that can
            # produce such a task
            #
            # @param [Roby::Task,Roby::TaskService] name
            # @returns [Array<ActionModel>]
            def find_all_actions_by_type(type)
                result = []
                each_action do |description|
                    if description.returned_type.fullfills?(type)
                        result << description
                    end
                end
                result
            end

            # Creates a state machine of actions
            def state_machine(name, &block)
                if !@current_description
                    raise ArgumentError, "you must describe the action with #describe before calling #state_machine"
                end

                root_m = @current_description.returned_type
                arguments = @current_description.arguments.map(&:name)
                machine_model = StateMachine.new_submodel(self, root_m, arguments)
                machine_model.parse(&block)

                define_method(name) do |*arguments|
                    plan.add(root = root_m.new)
                    machine_model.new(self.model, root, *arguments) 
                    root
                end
            end

            # Returns an action description if 'm' is the name of a known action
            #
            # @return [Action]
            def method_missing(m, *args, &block)
                if model = find_action_by_name(m.to_s)
                    if args.size > 1
                        raise ArgumentError, "expected zero or one argument, got #{args.size}"
                    end
                    return Action.new(model, *args)
                end
                super
            end
        end
    end
end

