module Roby
    module Actions
        module Models
        module ExecutionContext
            # A representation of a task of the execution context's task
            class Child < Task
                # @return [ExecutionContext,Child] the child's parent
                attr_reader :parent
                # @return [String] the child's role, relative to its parent
                attr_reader :role
                # The child's model
                attr_reader :model

                def initialize(parent, role, model)
                    @parent, @role, @model = parent, role, model
                end

                # @return [Actions::ExecutionContext::Child]
                def new(execution_context)
                    Actions::ExecutionContext::Child.new(execution_context, self)
                end
            end
        end
        end
    end
end


