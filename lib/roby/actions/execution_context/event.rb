module Roby
    module Actions
        class ExecutionContext
            # Representation of the context's root task
            class Event
                # @return [ExecutionContext] the underlying execution context
                attr_reader :execution_context
                # @return [ExecutionContext::Task] the task this event is part
                #   of
                attr_reader :task
                # @return [Models::ExecutionContext::Event]
                attr_reader :model

                def initialize(execution_context, model)
                    @execution_context = execution_context
                    @model = model
                    @task  = execution_context.instance_for(model.task_model)
                end

                def symbol; model.symbol end

                def resolve
                    task.resolve.event(model.symbol)
                end

                def to_s; "#{task}.#{symbol}_event" end
            end
        end
    end
end

