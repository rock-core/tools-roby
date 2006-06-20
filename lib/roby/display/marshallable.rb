require 'roby/event'
require 'roby/task'

module Roby
    module Display
	class Marshallable
	    attr_reader :source_id

	    alias :hash :source_id
	    def eql?(obj); source_id == obj.source_id end
	    alias :== :eql?

	    attr_reader :source_class
	    def source_address; Object.address_from_id(source_id) end

	    def initialize(source)
		@source_id    = source.object_id
		@source_class = source.class.name
		@name = source.model.name
	    end

	    attr_reader :name
	    def model; self end
	end
	
	# Serializable representation of Event
	# We use these objects instead of Event since the latter would
	# need too much DRb traffic
	class Event < Marshallable
	    @@cache = Hash.new
	    def self.[](event)
		@@cache[event] ||= if event.respond_to?(:task)
				       TaskEvent.new(event)
				   else
				       Event.new(event)
				   end
	    end
	    
	    attr_reader :symbol, :context
	    def initialize(event)
		@symbol = (event.symbol if event.respond_to?(:symbol)) || ""
		@context = (event.context.to_s if event.respond_to?(:context)) || ""
		super(event)
	    end
	end

	class TaskEvent < Event
	    attr_reader :task
	    def initialize(event)
		super(event)
		@task = Task[event.task]
	    end
	end

	# Serializable representation of Task.
	# We use these objects instead of Task since the latter would
	# need too much DRb traffic
	class Task < Marshallable
	    @@cache = Hash.new
	    def self.[](task); @@cache[task] ||= Task.new(task) end

	    attr_reader :name
	    def finished?; @finished end
	    def initialize(task)
		@name     = task.model.name
		@finished = task.finished?
		super(task)
	    end
	end
    end
end
	

