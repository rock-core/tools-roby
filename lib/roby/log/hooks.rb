require 'roby/log/logger'

module Roby::Log
    module DistributedObjectHooks
	HOOKS = %w{added_owner removed_owner}

	def added_owner(peer)
            super
	    Roby::Log.log(:added_owner) { [self, peer] }
	end

	def removed_owner(peer)
            super
	    Roby::Log.log(:removed_owner) { [self, peer] }
	end
    end
    Roby::DistributedObject.class_eval do
        prepend DistributedObjectHooks
    end

    module TaskHooks
	HOOKS = %w{task_failed_to_start}
        # task_failed_to_start(self, reason)
    end

    module ExecutablePlanHooks
	HOOKS = %w{
            added_edge removed_edge updated_edge_info merged_plan
            added_transaction removed_transaction
            notify_plan_status_change
        }
        # added_edge(self, parent, child, relations, info)
        # removed_edge(self, parent, child, relations)
        # updated_edge_info(self, parent, child, relation, info)
        # merged_plan(self, plan)

        # finalized_task(self, task)
        # finalized_event(self, event)

        # notify_plan_status_change(self, task, status)
        # garbage(self, object)

        # added_transaction(self, transaction)
        # removed_transaction(self, transaction)
    end

    module TransactionHooks
	HOOKS = %w{committed_transaction discarded_transaction}

	def committed_transaction
	    super
	    Roby::Log.log(:committed_transaction) { [self] }
	end
	def discarded_transaction
	    super
	    Roby::Log.log(:discarded_transaction) { [self] }
	end
    end
    Roby::Transaction.class_eval do
        prepend TransactionHooks
    end

    module EventGeneratorHooks
	HOOKS = %w{generator_calling generator_called
                   generator_emitting generator_fired
		   generator_propagate_event
                   generator_unreachable
		   generator_emit_failed}

        # generator_calling(generator_id, source_generators, context_as_string)
        # generator_called(generator_id, context_as_string)
        # generator_emitting(generator_id, source_generators, context_as_string)
        # generator_fired(generator_id, event_id, event_time, context_as_string)
        # generator_emit_failed(generator_id, error)
        # generator_propagate_event(is_forwarding, source_generator_id,
        #   target_generator_id, event_id, event_time, event_context_as_string)
        # generator_unreachable(generator_id, reason)
    end

    module ExecutionHooks
	HOOKS = %w{cycle_end exception_notification report_scheduler_state}

        # cycle_end(timings)

        # exception_notification(mode, error, involved_objects)
        #   mode == EXCEPTION_FATAL -> involved_objects Roby::Task
        #   mode == EXCEPTION_NONFATAL -> involved_objects Roby::Task
        #   mode == EXCEPTION_HANDLED -> involved_objects Roby::Task or Roby::Plan

        # report_scheduler_state(plan, pending_non_executable_tasks, called_generators, non_scheduled_tasks)
    end

    module TaskArgumentsHooks
        HOOKS=%w{task_arguments_updated}

        # task_arguments_updated(task, key, value)
    end

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
        # Note: in ruby 2.1+, we can get rid of this by having a decorator API
        #
        #   Log.define_hook def cycle_end(timings)
        #      ...
        #   end
	[TransactionHooks, DistributedObjectHooks, TaskHooks,
	    ExecutablePlanHooks, EventGeneratorHooks, ExecutionHooks, TaskArgumentsHooks].each do |klass|
		klass::HOOKS.each do |m|
		    yield(m.to_sym)
		end
	    end

        additional_hooks.each do |m|
            yield(m)
        end
    end
end

