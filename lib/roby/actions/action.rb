module Roby
    module Actions
        # The representation of an action, as a model and arguments
        class Action
            # The action model
            # @return [ActionModel]
            attr_accessor :model
            # The action arguments
            # @return [Hash]
            attr_reader :arguments

            def initialize(model, arguments = Hash.new)
                @model, @arguments = model, arguments
            end

            # The task model returned by this action
            def returned_type
                model.returned_type
            end

            # Returns a plan pattern that would deploy this action in the plan
            # @return [Roby::Task] the task, with a planning task of type
            #   {Actions::Task}
            def as_plan
                model.plan_pattern(arguments)
            end

            def rebind(action_interface_model)
                result = dup
                result.model = result.model.rebind(action_interface_model)
                result
            end

            # Deploys this action on the given plan
            def instanciate(plan, arguments = Hash.new)
                model.instanciate(plan, self.arguments.merge(arguments))
            end
        end
    end
end
