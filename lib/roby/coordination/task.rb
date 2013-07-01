module Roby
    module Coordination
            # Representation of a toplevel task in an execution context instance
            class Task < TaskBase
                # @return [nil,Roby::Task] the actual Roby task this is
                # representing
                attr_reader :task

                def initialize(execution_context, model)
                    super(execution_context, model)
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

                def to_s; "Task[#{model.model}]" end
            end
    end
end

