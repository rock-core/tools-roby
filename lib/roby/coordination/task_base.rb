# frozen_string_literal: true

module Roby
    module Coordination
        class ResolvingUnboundObject < RuntimeError; end

        # Base functionality for task-like objects in coordination models
        # (Task, Child)
        class TaskBase
            # @return [Base] the underlying execution context
            attr_reader :execution_context
            # @return [Coordination::Models::Task]
            attr_reader :model

            def initialize(execution_context, model)
                @execution_context = execution_context
                @model = model
            end

            # Method that must be reimplemented in the task objects actually
            # used in the coordination primitives
            def resolve
                raise NotImplementedError, "#resolve must be reimplemented in objects meant to be used in the coordination primitives"
            end

            def find_child(role, child_model = nil)
                child_model ||= model.find_child_model(role)
                unless child_model
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

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args,
                    "_child" => :find_child,
                    "_port" => :find_port,
                    "_event" => :find_event) || super
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, m,
                    "_child" => :has_child?,
                    "_port" => :has_port?,
                    "_event" => :has_event?) || super
            end

            include MetaRuby::DSLs::FindThroughMethodMissing

            def to_coordination_task(task_model)
                model.to_coordination_task(task_model)
            end
        end
    end
end
