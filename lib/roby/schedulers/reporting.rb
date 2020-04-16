# frozen_string_literal: true

require "roby/schedulers/state"

module Roby
    module Schedulers
        extend Logger::Hierarchy
        extend Logger::Forward

        class Reporting
            def report_pending_non_executable_task(msg, task, *args)
                Roby::Schedulers.debug { State.format_message_into_string(msg, task, *args) }
                plan.execution_engine.log(:scheduler_report_pending_non_executable_task, msg, task, *args)
            end

            def report_trigger(generator)
                Roby::Schedulers.debug { "called #{generator}" }
                plan.execution_engine.log(:scheduler_report_trigger, generator)
            end

            def report_holdoff(msg, task, *args)
                Roby::Schedulers.debug { State.format_message_into_string(msg, task, *args) }
                plan.execution_engine.log(:scheduler_report_holdoff, msg, task, *args)
            end

            def report_action(msg, task, *args)
                Roby::Schedulers.debug { State.format_message_into_string(msg, task, *args) }
                plan.execution_engine.log(:scheduler_report_action, msg, task, *args)
            end
        end
    end
end
