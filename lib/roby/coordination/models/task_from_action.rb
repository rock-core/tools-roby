module Roby
    module Coordination
        module Models

        # A representation of a state based on an action
        class TaskFromAction < TaskWithDependencies
            # The associated action
            # @return [Roby::Actions::Action]
            attr_accessor :action

            # Returns the coordination model that is used to define the
            # underlying action
            #
            # @return (see Models::Action#to_coordination_model)
            # @raise (see Models::Action#to_coordination_model)
            def to_coordination_model
                action.to_coordination_model
            end

            def initialize(action)
                @action = action
                super(action.model.returned_type)
            end

            # Rebind this task to refer to a different action interface
            def rebind(coordination_model)
                result = super
                result.action = action.rebind(coordination_model.action_interface)
                result.model  = result.action.model.returned_type
                result
            end

            # Generates a task for this state in the given plan and returns
            # it
            def instanciate(plan, variables = Hash.new)
                arguments = action.arguments.map_value do |key, value|
                    if value.respond_to?(:evaluate)
                        value.evaluate(variables)
                    else value
                    end
                end
                action.as_plan(arguments)
            end

            def to_s; "action(#{action})[#{model}]" end
        end
        end
    end
end

