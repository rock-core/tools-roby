require 'roby/log/logger'

module Roby::Log
    LOG_HOOKS = %w{
        register_executable_plan
        merged_plan
        added_edge
        updated_edge_info
        removed_edge
        notify_plan_status_change
        garbage
        finalized_task
        finalized_event
        task_arguments_updated
        task_failed_to_start
        generator_calling
        generator_called
        generator_emitting
        generator_fired
        generator_emit_failed
        generator_propagate_event
        generator_unreachable
        exception_notification
        report_scheduler_state
        cycle_end}.map(&:to_sym)

    class << self
        # Hooks that need to be registered for the benefit of generic loggers
        # such as {FileLogger}
        attr_reader :additional_hooks

        # Generic logging classes, e.g. that should log all log messages
        attr_reader :generic_loggers
    end
    @generic_loggers = Array.new
    @additional_hooks = Array.new

    def self.register_generic_logger(klass)
        each_hook do |m|
            klass.define_hook m
        end
        generic_loggers << klass
    end

    # Define a new logging hook (logging method) that should be logged on all
    # generic loggers
    def self.define_hook(m)
        additional_hooks << m
        generic_loggers.each do |l|
            l.define_hook(m)
        end
    end

    def self.each_hook
        LOG_HOOKS.each do |m|
            yield(m)
        end

        additional_hooks.each do |m|
            yield(m)
        end
    end
end

