module Roby
    module Actions
        module InterfaceModel
            # The set of actions defined on this interface
            #
            # @returns [Hash<String,ActionModel>]
            # @key_name action_name
            define_inherited_enumerable(:action, :actions, :map => true) { Hash.new }

            # Create a new action description that is going to be used to
            # describe the next method. Note that only methods that have a
            # description are exported as actions
            def describe(doc = nil)
                if @current_description
                    raise ArgumentError, "#{@current_description} started but never used. Did you forget to add a method to your action interface ?"
                end
                @current_description = ActionModel.new(self, doc)
            end

            # Registers the action that is currently described with the given
            # action name
            def register_current_action(name)
                description = @current_description.name = name
                actions[name] = @current_description
                @current_description = nil
                description
            end

            # Hook used to export methods for which there is a description
            def method_added(method_name)
                super
                if @current_description
                    register_current_action(method_name.to_s)
                end
            end

            # Returns the action description for the given action name, or nil
            # if there are none with that name
            #
            # @param [String] name
            # @returns [ActionModel,nil]
            def find_action_by_name(name)
                find_action(name)
            end

            # Returns all the action description for the actions that can
            # produce such a task
            #
            # @param [Roby::Task,Roby::TaskService] name
            # @returns [Array<ActionModel>]
            def find_all_actions_by_type(type)
                result = []
                each_action do |_, description|
                    if description.returned_type.fullfills?(type)
                        result << description
                    end
                end
                result
            end
        end
    end
end

