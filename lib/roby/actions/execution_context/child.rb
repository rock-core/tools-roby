module Roby
    module Actions
        class ExecutionContext
            # Representation of the context's root task
            class Child < Task
                # @return [ExecutionContext::Task] this child's parent
                attr_reader :parent

                def initialize(execution_context, model)
                    super
                    @parent = execution_context.instance_for(model.parent)
                end

                def resolve
                    parent.resolve.find_child_from_role(model.role)
                end
            end
        end
    end
end

