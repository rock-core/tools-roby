module Roby
    module Actions
        module Models
        module Interface
            # IMPORTANT: ModelAsClass / ModelAsModule must NOT be included here.
            # This interface model is used by both Interface (which is a
            # ModelAsClass) and Library (which is a ModelAsModule)
	    include Distributed::DRobyModel::Dump
            extend MetaRuby::Attributes

            def promote_registered_action(name, action)
                actions[name] ||= action.rebind(self)
            end

            # The set of actions defined on this interface
            #
            # @return [Hash<String,Models::Action>]
            # @key_name action_name
            inherited_attribute(:registered_action, :actions, :map => true) { Hash.new }

            # The set of fault response tables added to this action interface
            # @return [Array<Model<FaultResponseTable>>]
            inherited_attribute(:fault_response_table, :fault_response_tables) { Array.new }

            # Exception raised when an action is defined with the wrong count of
            # argument (zero if no arguments are specified and one if arguments
            # are specified)
            class ArgumentCountMismatch < ScriptError; end

            # Adds all actions defined in another action interface or in an
            # action library in this interface
            #
            # @param [Module,Interface]
            # @return [void]
            def use_library(library)
                if library <= Actions::Interface
                    library.each_registered_action do |name, action|
                        actions[name] = action
                    end
                    library.each_fault_response_table do |table|
                        use_fault_response_table table
                    end
                else
                    include library
                end
            end

            # Enumerates the actions registered on this interface
            #
            # @yieldparam [Models::Action] action
            def each_action
                return enum_for(:each_action) if !block_given?
                each_registered_action do |_, description|
                    yield(description)
                end
            end

            # Clears everything stored on this model
            def clear_model
                super
                actions.clear
            end

            # Create a new action description that is going to be used to
            # describe the next method. Note that only methods that have a
            # description are exported as actions
            #
            # @return Action
            def describe(doc = nil)
                if @current_description
                    Actions::Interface.warn "#{@current_description} started but never used. Did you forget to add a method to your action interface ?"
                end
                @current_description = Models::Action.new(self, doc)
            end

            # Registers a new action on this model
            #
            # If no specific return type has been specified, one is created
            # automatically and registered as a constant on this action
            # interface. For instance, the start_all_devices action would create
            # a simple StartAllDevices task model.
            def register_action(name, action_model)
                name = name.to_s
                if action_model.returned_type == Roby::Task
                    task_model_name = name.camelcase(:upper)
                    if const_defined_here?(task_model_name)
                        action_model.returns(const_get(task_model_name))
                    else
                        task_model = Roby::Task.new_submodel do
                            terminates
                        end
                        const_set task_model_name, task_model
                        task_model.permanent_model = self.permanent_model?
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
                    rescue ArgumentError => e
                        if expected_argument_count == 0
                            raise ArgumentCountMismatch, "action #{name} has been declared to have no arguments, the #{name} method must be callable without any arguments"
                        else
                            raise ArgumentCountMismatch, "action #{name} has been declared to have arguments, the #{name} method must be callable with a single Hash argument"
                        end
                    end
                    register_action(name, description)
                end
            end

            # Returns the action description for the given action name, or nil
            # if there are none with that name
            #
            # @param [String] name
            # @return [Models::Action,nil]
            def find_action_by_name(name)
                find_registered_action(name.to_s)
            end

            # Returns all the action description for the actions that can
            # produce such a task
            #
            # @param [Roby::Task,Roby::TaskService] type
            # @return [Array<Models::Action>]
            def find_all_actions_by_type(type)
                result = []
                each_action do |description|
                    if description.returned_type.fullfills?(type)
                        result << description
                    end
                end
                result
            end

            # Helper method for {action_state_machine} and {action_script}
            def action_coordination(name, model, &block)
                if !@current_description
                    raise ArgumentError, "you must describe the action with #describe before calling #action_coordination"
                end

                action_model, @current_description = @current_description, nil
                if name
                    # NOTE: this modifies #action_model to sane defaults
                    #       using the action name
                    register_action name, action_model
                end

                root_m = action_model.returned_type
                arguments = action_model.arguments.map(&:name)
                coordination_model = model.new_submodel(:action_interface => self, :root => root_m)

                action_model.arguments.each do |arg|
                    if !arg.required
                        coordination_model.argument arg.name, :default => arg.default
                    else
                        coordination_model.argument arg.name
                    end
                end
                coordination_model.parse(&block)
                action_model.coordination_model = coordination_model

                if name
                    define_method(name) do |*arguments|
                        plan.add(root = root_m.new)
                        coordination_model.new(self.model, root, *arguments) 
                        root
                    end
                end
                return action_model, coordination_model
            end

            # Defines an action from an
            # {Coordination::Models::ActionStateMachine}
            #
            # @param [String] name the name of the new action
            # @yield the action state machine definition
            # @return [Action,Coordination::Models::ActionStateMachine]
            #
            # The action state machine model can later be retrieved using
            # {Action#coordination_model}
            #
            # @example (see Coordination::Models::ActionStateMachine)
            def action_state_machine(name, &block)
                if !@current_description
                    raise ArgumentError, "you must describe the action with #describe before calling #action_state_machine"
                end

                #Define user-possible starting states, this will override the default starting state
                @current_description.optional_arg("start_state", :default => nil)
                action_coordination(name, Coordination::ActionStateMachine, &block)
            end

            # @deprecated use {action_state_machine} instead
            def state_machine(name, &block)
                action_state_machine(name, &block)
            end

            # Defines an action from an
            # {Coordination::Models::ActionScript}
            #
            # @param [String] name the name of the new action
            # @yield the action script definition
            # @return [Action,Coordination::Models::ActionScript]
            #
            # The action script model can later be retrieved using
            # {Action#coordination_model}
            def action_script(name, options = Hash.new, &block)
                if !@current_description
                    raise ArgumentError, "you must describe the action with #describe before calling #action_script"
                end
                action_coordination(name, Coordination::ActionScript, &block)
            end

            # Returns an action description if 'm' is the name of a known action
            #
            # @return [Action]
            def method_missing(m, *args, &block)
                if model = find_action_by_name(m.to_s)
                    if args.size > 1
                        raise ArgumentError, "expected zero or one argument, got #{args.size}"
                    end
                    return model.new(*args)
                end
                super
            end

            # Declare that this fault response table should be used on all plans
            # that are going to use this action interface
            def use_fault_response_table(table_model, arguments = Hash.new)
                table_model.validate_arguments(arguments)
                fault_response_tables << [table_model, arguments]
            end
        end
        end
    end
end

