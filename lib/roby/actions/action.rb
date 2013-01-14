module Roby
    module Actions
        # The representation of an action, as a model and arguments
        class Action
            # The action model
            # @return [ActionModel]
            attr_reader :model
            # The action arguments
            # @return [Hash]
            attr_reader :arguments

            def initialize(model, arguments)
                @model, @arguments = model, arguments
            end

            # Returns a plan pattern that would deploy this action in the plan
            # @return [Roby::Task] the task, with a planning task of type
            #   {Actions::Task}
            def as_plan
                planner = Actions::Task.new(
                    :action_model => model,
                    :action_arguments => arguments)
                planner.planned_task
            end
        end
    end
end
