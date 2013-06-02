module Roby
    module Actions
        class ExecutionContext
            class ResolvingUnboundObject < RuntimeError; end

            # Representation of a task in an execution context instance
            class Task
                # @return [ExecutionContext] the underlying execution context
                attr_reader :execution_context
                # @return [Actions::Models::ExecutionContext::Task]
                attr_reader :model
                # @return [nil,Roby::Task] the actual Roby task this is
                # representing
                attr_reader :task

                def initialize(execution_context, model)
                    @execution_context = execution_context
                    @model = model
                    @task  = nil
                end

                def bind(task)
                    @task = task
                end

                def resolve
                    if task then task
                    else raise ResolvingUnboundObject, "trying to resolve #{self}, which is not (yet) bound"
                    end
                end

                def to_s; "#<EE::Task model=#{model}" end
            end
        end
    end
end

