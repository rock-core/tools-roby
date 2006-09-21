require 'roby/log/logger'
require 'roby/log/marshallable'
require 'set'

module Roby::Log
    Wrapper = Roby::Marshallable::Wrapper

    module TaskHooks
	def added_child_object(to, type, info)
	    super if defined? super
	    Roby::Log.log(:added_task_relation) { [Time.now, type, Wrapper[self], Wrapper[to], info.inspect] }
	end

	def removed_child_object(to, type)
	    super if defined? super
	    Roby::Log.log(:removed_task_relation) { [Time.now, type, Wrapper[self], Wrapper[to]] }
	end

	def initialize(*args)
	    super if defined? super
	    Roby::Log.log(:task_initialize) { [Time.now, Wrapper[self], Wrapper[event(:start)], Wrapper[event(:stop)]] }
	end
    end
    Roby::Task.include TaskHooks

    module PlanHooks
	def finalized(task)
	    super if defined? super
	    Roby::Log.log(:finalized_task) { [Time.now, Wrapper[self], Wrapper[task]] }
	end
    end
    Roby::Plan.include PlanHooks

    module EventGeneratorHooks
	def added_child_object(to, type, info)
	    super if defined? super
	    Roby::Log.log(:added_event_relation) { [Time.now, type, Wrapper[self], Wrapper[to], info.inspect] }
	end

	def removed_child_object(to, type)
	    super if defined? super
	    Roby::Log.log(:removed_event_relation) { [Time.now, type, Wrapper[self], Wrapper[to]] }
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
end

