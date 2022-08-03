# frozen_string_literal: true

module Roby
    module Coordination
        module Models
            # A representation of a task of the execution context's task
            class Child < Task
                # @return [Base,Child] the child's parent
                attr_reader :parent
                # @return [String] the child's role, relative to its parent
                attr_reader :role

                def initialize(parent, role, model)
                    super(model)

                    @parent, @role = parent, role
                end

                def ==(other)
                    other.kind_of?(Child) &&
                        other.parent == parent &&
                        other.role == role &&
                        other.model == model
                end

                # @return [Coordination::Child]
                def new(execution_context)
                    Coordination::Child.new(execution_context, self)
                end

                def to_s
                    "#{parent}.#{role}_child[#{model}]"
                end
            end
        end
    end
end
