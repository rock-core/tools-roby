# frozen_string_literal: true

module Roby
    module Coordination
        # Representation of a toplevel task in an execution context instance
        class Task < TaskBase
            # @return [nil,Roby::Task] the actual Roby task this is
            #   representing
            attr_reader :task

            def initialize(execution_context, model)
                super(execution_context, model)
                @task = nil
            end

            def root_task
                self
            end

            # Associate this coordination task to the given roby task
            #
            # This sets the next value returned by #resolve
            #
            # @param [Roby::Task] task
            def bind(task)
                @task = task
            end

            # Resolves this to the actual task object
            #
            # @return [Roby::Task]
            # @raise ResolvingUnboundObject
            def resolve
                unless task
                    raise ResolvingUnboundObject,
                          "trying to resolve #{self}, which is not (yet) bound"
                end

                task
            end

            def name
                model.name
            end

            def to_s
                "Task[#{model.model}]"
            end
        end
    end
end
