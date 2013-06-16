module Roby
    module Coordination
        module Models
            # A representation of a task of the execution context's task
            class Child < Task
                # @return [Base,Child] the child's parent
                attr_reader :parent
                # @return [String] the child's role, relative to its parent
                attr_reader :role
                # The child's model
                attr_reader :model

                def initialize(parent, role, model)
                    @parent, @role, @model = parent, role, model
                end

                # @return [Coordination::Child]
                def new(execution_context)
                    Coordination::Child.new(execution_context, self)
                end

                def to_s; "#{parent}.#{role}_child[#{model}]" end
            end
        end
    end
end


