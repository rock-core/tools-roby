require 'roby/log/marshallable'
require 'roby/log/logger'

module Roby::Log
    Wrapper = Roby::Marshallable::Wrapper

    module RelationHooks
	def added_child_object(to, type, info)
	    super if defined? super

	    Roby::Log.each_logger(:added_relation) do |log|
		log.added_relation(Time.now, type, Wrapper[self], Wrapper[to], info)
	    end
	end

	def removed_child_object(to, type)
	    super if defined? super

	    Roby::Log.each_logger(:removed_relation) do |log|
		log.removed_relation(Time.now, type, Wrapper[self], Wrapper[to])
	    end
	end
    end

    module TaskHooks
	include RelationHooks

	def initialize(*args)
	    super if defined? super

	    Roby::Log.each_logger(:task_initialize) do |log|
		log.task_initialize(Time.now, Wrapper[self], Wrapper[event(:start)], Wrapper[event(:stop)])
	    end
	end
    end
    Roby::Task.include TaskHooks

    module EventGeneratorHooks
	include RelationHooks

	def calling(context)
	    super if defined? super
	    Roby::Log.each_logger(:generator_calling) do |log| 
		log.generator_calling(Time.now, Wrapper[self], context)
	    end
	end

	def fired(event)
	    super if defined? super
	    Roby::Log.each_logger(:generator_fired) do |log| 
		log.generator_fired(Time.now, Wrapper[event])
	    end
	end

	def signalling(event, to)
	    super if defined? super
	    Roby::Log.each_logger(:generator_signalling) do |log| 
		log.generator_signalling(Time.now, Wrapper[event], Wrapper[to])
	    end
	end
    end
    Roby::EventGenerator.include EventGeneratorHooks
end
