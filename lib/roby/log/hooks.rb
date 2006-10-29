require 'roby/log/logger'
require 'roby/log/marshallable'
require 'roby/plan'
require 'roby/task'
require 'roby/event'
require 'roby/control'
require 'set'

module Roby::Log
    Wrapper = Roby::Marshallable::Wrapper

    module TaskHooks
	HOOKS = %w{added_task_relation removed_task_relation task_initialize}

	def added_child_object(to, type, info)
	    super if defined? super
	    Roby::Log.log(:added_task_relation) { [Time.now, type.name, Wrapper[self], Wrapper[to], info.to_s] }
	end

	def removed_child_object(to, type)
	    super if defined? super
	    Roby::Log.log(:removed_task_relation) { [Time.now, type.name, Wrapper[self], Wrapper[to]] }
	end

	def initialize(*args)
	    super if defined? super
	    Roby::Log.log(:task_initialize) { [Time.now, Wrapper[self], Wrapper[event(:start)], Wrapper[event(:stop)]] }
	end
    end
    Roby::Task.include TaskHooks

    module PlanHooks
	HOOKS = %w{inserted_tasks discarded_tasks replaced_tasks discovered_tasks finalized_task}

	def inserted(tasks)
	    super if defined? super
	    Roby::Log.log(:inserted_tasks) { [Time.now, Wrapper[self], Wrapper[tasks]] }
	end
	def discarded(tasks)
	    super if defined? super
	    Roby::Log.log(:discarded_tasks) { [Time.now, Wrapper[self], Wrapper[tasks]] }
	end
	def replaced(from, to)
	    super if defined? super
	    Roby::Log.log(:replaced_tasks) { [Time.now, Wrapper[self], Wrapper[from], Wrapper[to]] }
	end
	def discovered(tasks)
	    super if defined? super
	    Roby::Log.log(:discovered_tasks) { [Time.now, Wrapper[self], Wrapper[tasks]] }
	end

	def finalized(task)
	    super if defined? super
	    Roby::Log.log(:finalized_task) { [Time.now, Wrapper[self], Wrapper[task]] }
	end
    end
    Roby::Plan.include PlanHooks

    module EventGeneratorHooks
	HOOKS = %w{added_event_relation removed_event_relation generator_calling generator_fired generator_signalling}

	def added_child_object(to, type, info)
	    super if defined? super
	    Roby::Log.log(:added_event_relation) { [Time.now, type.name, Wrapper[self], Wrapper[to], info.to_s] }
	end

	def removed_child_object(to, type)
	    super if defined? super
	    Roby::Log.log(:removed_event_relation) { [Time.now, type.name, Wrapper[self], Wrapper[to]] }
	end

	def calling(context)
	    super if defined? super
	    Roby::Log.log(:generator_calling) { [Time.now, Wrapper[self], context] }
	end

	def fired(event)
	    super if defined? super
	    Roby::Log.log(:generator_fired) { [Time.now, Wrapper[event]] }
	end

	def signalling(event, to)
	    super if defined? super
	    Roby::Log.log(:generator_signalling) { [Time.now, Wrapper[event], Wrapper[to]] }
	end
    end
    Roby::EventGenerator.include EventGeneratorHooks

    module ControlHooks
	HOOKS = %w{cycle_end}

	def cycle_end(timings)
	    super if defined? super
	    Roby::Log.log(:cycle_end) { [Time.now, timings] }
	end
    end
    Roby::Control.include ControlHooks
end

