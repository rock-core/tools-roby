# frozen_string_literal: true

module Roby::Tasks
    # Base functionality for the Sequence and Parallel aggregators
    class TaskAggregator < Roby::Task
        def initialize(arguments = {})
            @tasks = []
            @name = nil
            super
        end

        terminates
        event(:start, controlable: true)

        # The array of tasks that are aggregated by this object
        attr_reader :tasks

        # TODO: is this really necessary
        def each_task(&iterator)
            yield(self)
            tasks.each(&iterator)
        end

        # True if this aggregator has no tasks
        def empty?
            tasks.empty?
        end

        # Removes this aggregator from the plan
        def delete
            @name  = self.name
            @tasks = nil
            if plan
                plan.remove_task(self)
            else
                clear_relations
                freeze
            end
        end
    end
end
