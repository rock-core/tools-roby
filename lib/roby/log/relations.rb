require 'roby/log/logger'
require 'roby/log/drb'

module Roby::Display
    class Relations < DRbRemoteDisplay
	@@displays = []
	class << self
	    def display(relation)
		unless instance = @@displays.assoc(relation)
		    @@displays << (instance = [name, Relations.new(relation)])
		end
		instance.last
	    end

	    def connect(options = {})
		if !(relation = options.delete(:relation))
		    raise ArgumentError, "no relation given"
		end

		instance = display(relation)
		Roby::Log.loggers << instance
		instance.connect("relations", options.merge(:name => relation.name))
	    end
	end

	attr_reader :relation
	def initialize(relation)
	    @relation = relation
	end

	def disabled
	    @@displays.delete(@@displays.rassoc(self))
	    Roby::Log.loggers.delete(self)
	end

	def task_initialize(time, task, start, stop)
	    service.task_initialize(time, task, start, stop)
	end

	STATE_EVENTS = [:start, :success, :failed]
	def generator_fired(time, event)
	    generator = event.generator
	    return unless generator.respond_to?(:symbol)
	    if STATE_EVENTS.include?(generator.symbol)
		service.state_change(generator.task, generator.symbol)
	    end
	end

	def finalized_task(time, plan, task)
	    service.state_change(task, :finalized)
	end

	[:added_task_relation, :added_event_relation, :removed_task_relation, :removed_event_relation].each do |m|
	    define_method(m) do |time, type, from, to, *args| 
		if relation.subset?(type)
		    service.send(m, time, from, to)
		end
	    end
	end
    end
end


