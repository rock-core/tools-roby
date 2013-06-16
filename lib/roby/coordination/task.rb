module Roby
    module Coordination
            class ResolvingUnboundObject < RuntimeError; end

            class TaskBase
                # @return [Base] the underlying execution context
                attr_reader :execution_context
                # @return [Coordination::Models::Task]
                attr_reader :model

                def initialize(execution_context, model)
                    @execution_context = execution_context
                    @model = model
                end

                def find_child(role, child_model = nil)
                    if !child_model
                        begin
                            task = self.resolve
                            if child_task = task.find_child_from_role(role)
                                child_model = child_task.model
                            end
                        rescue ResolvingUnboundObject
                        end
                    end

                    if child = model.find_child(role, child_model)
                        execution_context.instance_for(child)
                    end
                end

                def find_event(symbol)
                    if event = model.find_event(symbol)
                        execution_context.instance_for(event)
                    end
                end

                def method_missing(m, *args, &block)
                    case m.to_s
                    when /(.*)_child/
                        if !args.empty?
                            raise ArgumentError, "expected zero arguments, got #{args.size}"
                        elsif child = find_child($1)
                            child
                        else raise NoMethodError, "#{self} has no child named #{$1}"
                        end
                    when /(.*)_event/
                        if !args.empty?
                            raise ArgumentError, "expected zero arguments, got #{args.size}"
                        elsif event = find_event($1)
                            event
                        else raise NoMethodError, "#{self} has no event named #{$1}"
                        end
                    else super
                    end
                end

                def to_coordination_task(task_model); model.to_coordination_task(task_model) end
            end

            # Representation of a task in an execution context instance
            class Task < TaskBase
                # @return [nil,Roby::Task] the actual Roby task this is
                # representing
                attr_reader :task

                def initialize(execution_context, model)
                    super(execution_context, model)
                    @task  = nil
                end

                def bind(task)
                    @task = task
                end

                def resolve
                    if task then task
                    else raise ResolvingUnboundObject, "trying to resolve #{self}, which is not (yet) bound"
                    end
                end

                def to_s; "#<EE::Task model=#{model}" end
            end
    end
end

