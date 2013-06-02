module Roby
    module Actions
        module Models
        module ActionCoordination

        # A representation of a state based on an action
        class TaskFromAction < TaskWithDependencies
            # The associated action
            # @return [Roby::Actions::Action]
            attr_reader :action

            def initialize(action)
                @action = action
                super(action.model.returned_type)
            end

            # Generates a task for this state in the given plan and returns
            # it
            def instanciate(action_interface_model, plan, variables)
                arguments = action.arguments.map_value do |key, value|
                    if value.respond_to?(:evaluate)
                        value.evaluate(variables)
                    else value
                    end
                end
                action.rebind(action_interface_model).instanciate(plan, arguments)
            end

            def to_s; "action(#{action})[#{model}]" end
        end
        end
        end
    end
end

