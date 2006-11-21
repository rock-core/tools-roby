require 'roby/event'
require 'roby/task'
require 'roby/plan'
require 'roby/transactions'
require 'typelib'

module Roby
    module Marshallable
	# Base class for marshallable versions of plan objects (tasks, event generators, events)
	class Wrapper
	    @@cache = Hash.new
	    def self.marshalable?(object)
		case object
		when Time
		    true
		else
		    Kernel.immediate?(object) || object.nil?
		end
	    end

	    # Returns a marshallable wrapper for +object+
	    def self.[](object)
		ObjectSpace.define_finalizer(object, &method(:finalized))
		unless wrapper = @@cache[object.object_id] 
		    wrapper = @@cache[object.object_id] =
			case object
			when Roby::Transactions::Proxy:	TransactionProxy.new(object)
			when Roby::TaskEvent:		TaskEvent.new(object)
			when Roby::Event:		Event.new(object)
			when Roby::TaskEventGenerator:	TaskEventGenerator.new(object)
			when Roby::EventGenerator:	EventGenerator.new(object)
			when Roby::Task:		Task.new(object)
			when Roby::Transaction:		Transaction.new(object)
			when Roby::Plan:		Plan.new(object)
			when Exception:			WrappedException.new(object)
			when Module
			    object.name
			when Hash
			    object.inject({}) do |result, (k, v)| 
				k, v = Wrapper[k], Wrapper[v]
				result[k] = v
				result
			    end

			else 
			    if object.respond_to?(:map)
				object.map(&method(:[]))
			    elsif marshalable?(object)
				object
			    else
				raise TypeError, "unmarshallable object #{object} of type #{object.class}"
			    end
			end
		end

		if Wrapper === wrapper
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
	    def to_s; name || "#{source_class}:0x#{Object.address_from_id(source_id).to_s(16)}" end

	    def initialize(source)
		update(source)
	    end
	    def update(source)
		@source_id    = source.object_id
		@source_class = source.class.name
		@name	      = source.name if source.respond_to?(:name)
	    end
	end

	class WrappedException
	    attr_reader :message, :backtrace, :type
	    def initialize(obj)
		@message = obj.message
		@backtrace = obj.backtrace
		@type = obj.class.name
	    end
	    def to_s
		"'(#{type})#{message}'"
	    end
	end

	# Marshallable representation of plans
	class Plan < Wrapper
	    # The missions
	    attr_reader :missions
	    # The plan size
	    attr_reader :size

	    def update(plan)
		super
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

	class TransactionProxy < Wrapper
	    attr_reader :proxy_for
	    # Beware: we don't have a :transaction attribute since
	    # it would introduce a stack overflow:
	    #	Plan#update wraps missions -> a TransactionProxy is wrapped -> 
	    #	    Transaction#update is called -> Plan#update is called
	    def name; "Proxy(#{proxy_for.name})" end

	    def update(proxy)
		super
		@proxy_for = Wrapper[proxy.__getobj__]
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
		super
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
		super
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

	    def to_s
		"#{task}/#{symbol}"
	    end

	    def update(generator)
		super
		@symbol = generator.symbol
		@task = Wrapper[generator.task]
	    end
	end

	# Marshallable representation of Task
	class Task < Wrapper
	end
    end
end

