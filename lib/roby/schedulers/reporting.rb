require 'roby/schedulers/state'

module Roby
    module Schedulers
        extend Logger::Hierarchy
        extend Logger::Forward

        class Reporting
            attr_reader :state

            def initialize
                clear_reports
            end

            def clear_reports
                @state = State.new
            end

            def report_pending_non_executable_task(*args)
                Roby::Schedulers.debug { State.format_message_into_string(*args) }
                state.pending_non_executable_tasks << args
            end

            def report_trigger(event)
                Roby::Schedulers.debug { "called #{event}" }
                state.called_generators << event
            end

            def report_holdoff(msg, task, *args)
                Roby::Schedulers.debug { State.format_message_into_string(msg, task, *args) }
                state.non_scheduled_tasks[task] << [msg, args]
            end
        end
    end
end

