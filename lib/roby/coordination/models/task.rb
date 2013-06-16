module Roby
    module Coordination
        module Models
            # A task within an execution context
            class Task
                # The task model
                attr_reader :model

                def initialize(model)
                    @model = model
                end

                # @return [Coordination::Task]
                def new(execution_context)
                    Coordination::Task.new(execution_context, self)
                end

                def find_event(event_name)
                    if model && model.respond_to?(:find_event)
                        if event_model = model.find_event(event_name.to_sym)
                            return Event.new(self, event_name)
                        else
                        end
                    else return Event.new(self, event_name)
                    end
                end

                def find_child(role, child_model = nil)
                    if model && model.respond_to?(:find_child)
                        if child_model = model.find_child(role)
                            return Child.new(self, role, child_model)
                        else
                            raise ArgumentError, "#{model.name} has no child called #{role}"
                        end
                    else return Child.new(self, role, child_model)
                    end
                end

                def method_missing(m, *args, &block)
                    case m.to_s
                    when /^(.*)_event$/
                        event_name = $1
                        if event = find_event(event_name)
                            return event
                        else
                            raise ArgumentError, "#{model.name} has no event called #{event_name}"
                        end
                    when /^(.*)_child$/
                        role = $1
                        if child = find_child(role)
                            return child
                        else
                            raise ArgumentError, "#{model.name} has no child with the role #{role}"
                        end
                    else
                        super
                    end
                end

                def to_coordination_task(task_model = Roby::Task)
                    self
                end
            end
        end
    end
end

