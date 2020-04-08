# frozen_string_literal: true

module Roby
    module Coordination
        module Models
            # A representation of a state based on an action
            class TaskFromAction < TaskWithDependencies
                # The associated action
                # @return [Roby::Actions::Action]
                attr_accessor :action

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
                def instanciate(plan, variables = {})
                    arguments = action.arguments.transform_values do |value|
                        if value.respond_to?(:evaluate)
                            value.evaluate(variables)
                        else value
                        end
                    end
                    action.as_plan(arguments)
                end

                # Returns the action's underlying coordination model if there is one
                #
                # @return [nil,Base]
                def action_coordination_model
                    if action.model.respond_to?(:coordination_model)
                        action.model.coordination_model
                    end
                end

                def to_s
                    "action(#{action})[#{model}]"
                end
            end
        end
    end
end
