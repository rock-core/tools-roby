require 'roby/log/logger'
require 'roby/log/drb'

module Roby::Display
    class Relations < DRbRemoteDisplay
	@@displays = []
	class << self
	    def display(relation)
		unless instance = @@displays.assoc(relation)
		    @@displays << (instance = [name, EventStructure.new(relation)])
		end
		instance.last
	    end

	    def connect(options = {})
		relation = (options.delete(:relation) || default_structure)

		instance = display(relation)
		Roby::Log.loggers << instance
		instance.connect(self.name.gsub(/.*::/, ''), options.merge(:name => relation.name))
	    end
	end

	attr_reader :relation
	def initialize(relation)
	    @relation = relation
	end

	def disconnect
	    @displays.delete(@displays.rassoc(self))
	    Roby::Log.loggers.delete(self)
	end

	def added_relation(time, type, from, to, info)
	    if relation.subset?(type)
		service.added_relation(time, from, to)
	    end
	end

	def removed_relation(time, type, from, to)
	    if relation.subset?(type)
		service.removed_relation(time, from, to)
	    end
	end
    end

    class EventStructure < Relations
	class << self
	    def default_structure; Roby::EventStructure::CausalLinks end
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
    end

    class TaskStructure < Relations
	class << self
	    def default_structure; Roby::TaskStructure::Hierarchy end
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
    end

end


