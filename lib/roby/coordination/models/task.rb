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
                        end
                    else return Event.new(self, event_name)
                    end
                end

                def find_child(role, child_model = nil)
                    if model && model.respond_to?(:find_child)
                        model_child = model.find_child(role)
                        if model_child
                            return Child.new(self, role, child_model || model_child)
                        end
                    else return Child.new(self, role, child_model)
                    end
                end

                def method_missing(m, *args, &block)
                    case m.to_s
                    when /^(.*)_event$/
                        if !args.empty?
                            raise ArgumentError, "#{m} takes no arguments, #{args.size} given"
                        end

                        event_name = $1
                        if event = find_event(event_name)
                            return event
                        else
                            raise NoMethodError.new("#{model.name} has no event called #{event_name}", m)
                        end
                    when /^(.*)_child$/
                        if !args.empty?
                            raise ArgumentError, "#{m} takes no arguments, #{args.size} given"
                        end

                        role = $1
                        if child = find_child(role)
                            return child
                        else
                            raise NoMethodError.new("#{model.name} has no child with the role #{role}", m)
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

