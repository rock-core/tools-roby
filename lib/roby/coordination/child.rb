# frozen_string_literal: true

module Roby
    module Coordination
        # Representation of the context's root task
        class Child < TaskBase
            # @return [Coordination::Task] this child's parent
            attr_reader :parent

            def root_task
                parent
            end

            def initialize(execution_context, model)
                super
                @parent = execution_context.instance_for(model.parent)
            end

            def resolve
                if (result = parent.resolve.find_child_from_role(model.role))
                    result
                else
                    raise ResolvingUnboundObject, "#{parent.resolve}, resolved from #{parent} has not child named #{model.role}"
                end
            end

            def to_s
                "#{parent}.#{model.role}_child[#{model.model}]"
            end
        end
    end
end
