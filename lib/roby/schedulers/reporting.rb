require 'roby/schedulers/state'

module Roby
    module Schedulers
        class Reporting
            attr_reader :state

            def initialize
                clear_reports
            end

            def clear_reports
                @state = State.new
            end

            def report_pending_non_executable_task(*args)
                state.pending_non_executable_tasks << args
            end

            def report_trigger(event)
                state.called_generators << event
            end

            def report_holdoff(msg, task, *args)
                state.non_scheduled_tasks[task] << [msg, args]
            end
        end
    end
end

