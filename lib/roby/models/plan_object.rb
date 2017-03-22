module Roby
    module Models
        module PlanObject
            include MetaRuby::ModelAsClass
            extend MetaRuby::Attributes
            include Transaction::Proxying::Cache

            # @return [Array<UnboundMethod>] set of finalization handlers
            #   defined at the model level
            # @see PlanObject.when_finalized
            inherited_attribute(:finalization_handler, :finalization_handlers) { Array.new }

            # Adds a model-level finalization handler, i.e. a handler that will be
            # called on every instance of the class
            #
            # The block is called in the context of the task that got finalized
            # (i.e. in the block, self is this task)
            #
            # @return [void]
            def when_finalized(&block)
                method_name = "finalization_handler_#{block.object_id}"
                define_method(method_name, &block)
                finalization_handlers << instance_method(method_name)
            end

            # If true, the backtrace at which a plan object is finalized is
            # stored in this object's {PlanObject#removed_at} attribute.
            #
            # It defaults to false
            #
            # @see PlanObject#finalized!
            attr_predicate :debug_finalization_place?, true

            # This class method sets up the enclosing class as a child object,
            # with the root object being returned by the given attribute.
            # Task event generators are for instance defined by
            #
            #   class TaskEventGenerator < EventGenerator
            #       # The task this generator belongs to
            #       attr_reader :task
            #
            #       child_plan_object :task
            #   end
            def child_plan_object(attribute)
                class_eval <<-EOD, __FILE__, __LINE__+1
                def root_object; #{attribute} end
                def root_object?; false end
                def owners; #{attribute}.owners end
                def distribute?; #{attribute}.distribute? end
                def plan; #{attribute}.plan end
                def executable?; #{attribute}.executable? end

                def subscribed?; #{attribute}.subscribed? end
                def updated?; #{attribute}.updated? end
                def updated_by?(peer); #{attribute}.updated_by?(peer) end
                def update_on?(peer); #{attribute}.update_on?(peer) end
                def updated_peers; #{attribute}.updated_peers end
                def remotely_useful?; #{attribute}.remotely_useful? end

                def forget_peer(peer)
                    remove_sibling_for(peer)
                end
                def sibling_of(remote_object, peer)
                    if !distribute?
                        raise ArgumentError, "#{self} is local only"
                    end

                    add_sibling_for(peer, remote_object)
                end
            
                private :plan=
                private :executable=
                EOD
            end

            # Create a {Queries::PlanObjectMatcher}
            def match
                Queries::PlanObjectMatcher.new.with_model(self)
            end
        end
    end
end

