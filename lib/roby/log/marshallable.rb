require 'roby/event'
require 'roby/task'

module Roby
    module Marshallable
	# Base class for marshallable versions of plan objects (tasks, event generators, events)
	class Wrapper
	    @@cache = Hash.new
	    # Returns a marshallable wrapper for +object+
	    def self.[](object)
		ObjectSpace.define_finalizer(object, &method(:finalized))
		wrapper = (@@cache[object.object_id] ||= 
		    case object
		    when Roby::TaskEvent:   TaskEvent.new(object)
		    when Roby::Event:	    Event.new(object)
		    when Roby::TaskEventGenerator:   TaskEventGenerator.new(object)
		    when Roby::EventGenerator:	    EventGenerator.new(object)
		    when Roby::Task:	    Task.new(object)
		    when Roby::Transaction: Transaction.new(object)
		    when Roby::Plan:	    Plan.new(object)
		    else 
			if object.respond_to?(:each)
			    object.map do |o| 
				w = Wrapper[o]
				w.update(o)
				w
			    end
			else
			    raise TypeError, "unmarshallable object #{object}"
			end
		    end)

		unless wrapper.respond_to?(:each)
		    wrapper.update(object)
		end
		
		wrapper
	    end
	    # Called by the GC when a wrapped object is finalized
	    def self.finalized(id)
		@cache.delete(id)
	    end
	
	    # object_id of the real object
	    attr_reader :source_id
	    alias :hash :source_id
	    def eql?(obj); source_id == obj.source_id end
	    alias :== :eql?

	    def source_address
		Object.address_from_id(source_id)
	    end

	    # Class of the real object
	    attr_reader :source_class
	    # Address of the real object
	    def source_address; Object.address_from_id(source_id) end
	    # Name of the real object
	    attr_reader :name

	    def initialize(source)
		update(source)
	    end
	    def update(source)
		@source_id    = source.object_id
		@source_class = source.class.name
		@name	      = source.name
	    end
	end

	# Marshallable representation of plans
	class Plan < Wrapper
	    # The missions
	    attr_reader :missions
	    # The plan size
	    attr_reader :size

	    def update(plan)
		@size = plan.size
		@missions = plan.missions.map { |t| Wrapper[t] }
	    end
	end
	class Transaction < Plan
	    attr_reader :plan

	    def update(trsc)
		super
		@plan = Wrapper[trsc.plan]
	    end
	end
	
	# Marshallable representation of Event
	class Event < Wrapper
	    # The generator object
	    attr_reader :generator
	    # The propagation ID
	    attr_reader :propagation_id
	    # The event context
	    attr_reader :context

	    def update(event)
		super(event)
		@symbol    = event.propagation_id
		@context   = event.context.to_s
		@generator = Wrapper[event.generator]
	    end
	end

	# Marshallable representation of TaskEvent
	class TaskEvent < Event
	    # The task this event is based on
	    attr_reader :task
	    # The event symbol
	    attr_reader :symbol

	    def update(event)
		super(event)
		@task	= Wrapper[event.task]
		@symbol = event.symbol
	    end
	end

	# Marshallable representation of EventGenerator
	class EventGenerator < Wrapper
	end

	# Marshallable representation of TaskEventGenerator
	class TaskEventGenerator < EventGenerator
	    # The task this generator is part of
	    attr_reader :task
	    # The generator symbol
	    attr_reader :symbol

	    def update(generator)
		super(generator)
		@symbol = generator.symbol
		@task = Wrapper[generator.task]
	    end
	end

	# Marshallable representation of Task
	class Task < Wrapper
	end
    end
end

