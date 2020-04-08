# frozen_string_literal: true

module Roby
    module GUI
        # Determine the state a task had at a certain point in time, for display
        # purposes
        #
        # @param [Task] task
        # @param [Time] time
        # @return [Symbol] one of :pending, :running, :success or :finished
        def self.task_state_at(task, time)
            if task.failed_to_start?
                if task.failed_to_start_time > time
                    return :pending
                else
                    return :finished
                end
            end

            last_emitted_event = nil
            task.history.each do |ev|
                break if ev.time > time

                last_emitted_event = ev
            end

            unless last_emitted_event
                return :pending
            end

            gen = last_emitted_event.generator
            if !gen
                :pending
            elsif gen.terminal?
                %i[success finished running].find { |flag| task.send("#{flag}?") }
            else
                :running
            end
        end
    end
end
