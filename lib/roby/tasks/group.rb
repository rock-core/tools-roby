# frozen_string_literal: true

module Roby::Tasks
    class Group < Roby::Task
        def initialize(*tasks)
            super()
            if tasks.empty? || tasks.first.kind_of?(Hash)
                return
            end

            success = Roby::AndGenerator.new
            tasks.each do |task|
                depends_on task
                task.event(:success).signals success
            end
            success.forward_to event(:success)
        end

        event :start do |context|
            children.each do |child|
                if child.pending? && child.event(:start).root?
                    child.start!
                end
            end
            start_event.emit
        end
        terminates
    end
end
