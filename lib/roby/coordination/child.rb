module Roby
    module Coordination
            # Representation of the context's root task
            class Child < TaskBase
                # @return [Coordination::Task] this child's parent
                attr_reader :parent

                def initialize(execution_context, model)
                    super
                    @parent = execution_context.instance_for(model.parent)
                end

                def resolve
                    if result = parent.resolve.find_child_from_role(model.role)
                        result
                    else raise ResolvingUnboundObject, "#{parent.resolve}, resolved from #{parent} has not child named #{model.role}"
                    end
                end
            end
    end
end

