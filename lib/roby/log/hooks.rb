require 'roby/log/logger'
require 'roby'

module Roby::Log
    module TaskHooks
	HOOKS = %w{added_task_child removed_task_child}

	def added_child_object(child, relations, info)
	    super if defined? super
	    Roby::Log.log(:added_task_child) { [self, relations, child, info] }
	end

	def removed_child_object(child, relations)
	    super if defined? super
	    Roby::Log.log(:removed_task_child) { [self, relations, child] }
	end
    end
    Roby::Task.include TaskHooks

    module PlanHooks
	HOOKS = %w{inserted_tasks discarded_tasks replaced_tasks 
		   discovered_tasks discovered_events 
		   garbage_task finalized_task finalized_event 
		   added_transaction removed_transaction}

	def inserted(tasks)
	    super if defined? super
	    Roby::Log.log(:inserted_tasks) { [self, tasks] }
	end
	def discarded(tasks)
	    super if defined? super
	    Roby::Log.log(:discarded_tasks) { [self, tasks] }
	end
	def replaced(from, to)
	    super if defined? super
	    Roby::Log.log(:replaced_tasks) { [self, from, to] }
	end
	def discovered_events(tasks)
	    super if defined? super
	    Roby::Log.log(:discovered_events) { [self, tasks] }
	end
	def discovered_tasks(tasks)
	    super if defined? super
	    Roby::Log.log(:discovered_tasks) { [self, tasks] }
	end
	def garbage(task)
	    super if defined? super
	    Roby::Log.log(:garbage_task) { [self, task] }
	end
	def finalized_event(event)
	    super if defined? super
	    Roby::Log.log(:finalized_event) { [self, event] }
	end
	def finalized_task(task)
	    super if defined? super
	    Roby::Log.log(:finalized_task) { [self, task] }
	end

	def added_transaction(trsc)
	    super if defined? super
	    Roby::Log.log(:added_transaction) { [self, trsc] }
	end
	def removed_transaction(trsc)
	    super if defined? super
	    Roby::Log.log(:removed_transaction) { [self, trsc] }
	end
    end
    Roby::Plan.include PlanHooks

    module TransactionHooks
	HOOKS = %w{committed_transaction discarded_transaction}

	def committed_transaction
	    super if defined? super
	    Roby::Log.log(:committed_transaction) { [self] }
	end
	def discarded_transaction
	    super if defined? super
	    Roby::Log.log(:discarded_transaction) { [self] }
	end
    end
    Roby::Transaction.include TransactionHooks

    module EventGeneratorHooks
	HOOKS = %w{added_event_child removed_event_child 
		   generator_calling generator_called generator_fired
		   generator_signalling generator_forwarding generator_emitting
		   generator_postponed}

	def added_child_object(to, relations, info)
	    super if defined? super
	    Roby::Log.log(:added_event_child) { [self, relations, to, info] }
	end

	def removed_child_object(to, relations)
	    super if defined? super
	    Roby::Log.log(:removed_event_child) { [self, relations, to] }
	end

	def calling(context)
	    super if defined? super
	    Roby::Log.log(:generator_calling) { [self, Roby::Propagation.source_generators, context.to_s] }
	end

	def called(context)
	    super if defined? super
	    Roby::Log.log(:generator_called) { [self, context.to_s] }
	end

	def fired(event)
	    super if defined? super
	    Roby::Log.log(:generator_fired) { [self, event.object_id, event.time, event.context.to_s] }
	end

	def signalling(event, to)
	    super if defined? super
	    Roby::Log.log(:generator_signalling) { [false, self, to, event.object_id, event.time, event.context.to_s] }
	end

	def emitting(context)
	    super if defined? super
	    Roby::Log.log(:generator_emitting) { [self, Roby::Propagation.source_generators, context.to_s] }
	end

	def forwarding(event, to)
	    super if defined? super
	    Roby::Log.log(:generator_forwarding) { [true, self, to, event.object_id, event.time, event.context.to_s] }
	end

	def postponed(context, generator, reason)
	    super if defined? super 
	    Roby::Log.log(:generator_postponed) { [self, context.to_s, generator, reason.to_s] }
	end	
    end
    Roby::EventGenerator.include EventGeneratorHooks

    module ControlHooks
	HOOKS = %w{cycle_end}

	def cycle_end(timings)
	    super if defined? super
	    Roby::Log.log(:cycle_end) { [timings] }
	end

	module ClassExtension
	    HOOKS = %w{fatal_exception handled_exception}

	    def fatal_exception(error, tasks)
		super if defined? super
		Roby::Log.log(:fatal_exception) { [error.exception, tasks] }
	    end
	    def handled_exception(error, task)
		super if defined? super
		Roby::Log.log(:handled_exception) { [error.exception, task] }
	    end
	end
    end
    Roby::Control.include ControlHooks

    def self.each_hook
	[TransactionHooks, TaskHooks, PlanHooks, EventGeneratorHooks, ControlHooks, ControlHooks::ClassExtension].each do |klass|
	    klass::HOOKS.each do |m|
		yield(klass, m.to_sym)
	    end
	end
    end
end

