module Roby
    module Coordination
        module Models

        # A representation of a state based on an action
        class TaskFromAction < TaskWithDependencies
            # The associated action
            # @return [Roby::Actions::Action]
            attr_reader :action

            def initialize(action)
                @action = action
                super(action.model.returned_type)
            end

            def new(coordination_model)
                if coordination_model.action_interface_model < action.model.action_interface_model
                    TaskFromAction.new(action.rebind(coordination_model.action_interface_model)).new(coordination_model)
                else
                    return super
                end
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

