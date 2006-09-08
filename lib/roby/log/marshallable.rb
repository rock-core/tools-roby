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
		@@cache[object.object_id] ||= 
		    case object
		    when Roby::TaskEvent:   TaskEvent.new(object)
		    when Roby::Event:	    Event.new(object)
		    when Roby::TaskEventGenerator:   TaskEventGenerator.new(object)
		    when Roby::EventGenerator:	    EventGenerator.new(object)
		    when Roby::Task:	    Task.new(object)
		    end
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

	    # Class of the real object
	    attr_reader :source_class
	    # Address of the real object
	    def source_address; Object.address_from_id(source_id) end
	    # Model name of the real object
	    attr_reader :model_name

	    def initialize(source)
		@source_id    = source.object_id
		@source_class = source.class.name
		@model_name   = source.model.name
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

	    def initialize(event)
		@symbol    = event.propagation_id
		@context   = event.context.to_s
		@generator = Wrapper[event.generator]
		super(event)
	    end
	end

	# Marshallable representation of TaskEvent
	class TaskEvent < Event
	    # The task this event is based on
	    attr_reader :task
	    # The event symbol
	    attr_reader :symbol

	    def initialize(event)
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
	    def initialize
		super
		@symbol = generator.model.symbol
	    end

	    def initialize(generator)
		super(generator)
		@task = Wrapper[generator.task]
	    end
	end

	# Marshallable representation of Task
	class Task < Wrapper
	end
    end
end

