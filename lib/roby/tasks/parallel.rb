# frozen_string_literal: true

module Roby::Tasks
    class Parallel < TaskAggregator
        def name
            @name || @tasks.map(&:name).join("|")
        end

        attr_reader :children_success
        def initialize(arguments = {})
            super

            @children_success = Roby::AndGenerator.new
            @children_success.forward_to success_event
        end

        def child_of(task = nil)
            return super() unless task

            task = task.new unless task.kind_of?(Roby::Task)
            @tasks.each do |t|
                task.depends_on t
                task.start_event.signals t.start_event
            end
            children_success.forward_to task.success_event

            delete

            task
        end

        def <<(task)
            raise "trying to change a running parallel task" if running?

            @tasks << task

            start_event.signals task.start_event
            depends_on task
            children_success << task.success_event

            self
        end

        def to_parallel
            self
        end
    end
end
