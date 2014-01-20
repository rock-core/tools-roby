module Roby
    module Coordination
        module Models
            # A task within an execution context
            class Task
                # The task model
                attr_reader :model
                # The task name
                attr_accessor :name

                def initialize(model)
                    @model = model
                end

                # @return [Coordination::Task]
                def new(execution_context)
                    Coordination::Task.new(execution_context, self)
                end

                def has_event?(event_name)
                    if model && model.respond_to?(:find_event)
                        model.find_event(event_name.to_sym)
                    else true
                    end
                end

                def find_event(event_name)
                    if has_event?(event_name)
                        return Event.new(self, event_name)
                    end
                end

                def can_resolve_child_models?
                    model && model.respond_to?(:find_child)
                end

                def has_child?(role)
                    find_child_model(role) ||
                        !can_resolve_child_models?
                end

                def find_child_model(role)
                    if can_resolve_child_models?
                        model.find_child(role)
                    end
                end

                def find_child(role, child_model = nil)
                    if has_child?(role)
                        return Child.new(self, role, child_model || find_child_model(role))
                    end
                end

                def method_missing(m, *args, &block)
                    MetaRuby::DSLs.find_through_method_missing(self, m, args, 'event', 'child') ||
                        super
                end

                def to_coordination_task(task_model = Roby::Task)
                    self
                end
            end
        end
    end
end

