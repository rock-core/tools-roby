require 'set'

module Roby
    # Base class for event models
    # When events are emitted, then the created object is 
    # an instance of a particular Event class
    class Event
        # The task which fired this event
        attr_reader :task
        # The event context
        attr_reader :context
        
        def initialize(task, context = nil)
            @task = task
            @context  = context
        end

        # If the event model defines a controlable event
        def self.controlable?; respond_to?(:call) end
        # If the event is controlable
        def controlable?; self.class.controlable? end
        # If the event model defines a terminal event
        def self.terminal?; @terminal end
        # If the event is terminal
        def terminal?; self.class.controlable? end
        # The event symbol
        def self.symbol; @symbol end
        # The event symbol
        def symbol; self.class.symbol end
    end

    # Generic double-dispatchers for operation on
    # bound events, based on to_and and to_or
    module Event::ModelOperations
        def |(event_model)
            if event_model.respond_to?(:to_or)
                event_model.to_or | self
            else
                OrEvent.new << self << event_model
            end
        end
        def &(event_model)
            if event_model.respond_to?(:to_and)
                event_model.to_and & self
            else
                AndEvent.new << self << event_model
            end
        end

    end

    # An event model bound to a particular task instance
    # The Task/BoundEvent/Event relationship is 
    # comparable to the Class/UnboundMethod/Method one:
    # * a Task object is a model for a task, a Class in a model for an object
    # * an Event object is a model for an event instance (the instance being unspecified), 
    #   an UnboundMethod is a model for an instance method
    # * a BoundEvent object represents a particular event model 
    #   *bound* to a particular task instance,
    #   a Method object represents a particular method bound to a particular object
    class BoundEvent
        include Event::ModelOperations
        attr_reader :task, :event_model
        def initialize(task, event_model); @task, @event_model = task, event_model end
        def emit(context); task.emit(event_model, context) end
        def on(*args, &proc); task.on(event_model, *args, &proc) end

        # For the sake of simplicity, BoundEvent should be comparable
        # to [task, event_model]
        def ==(description); [task, event_model] == description end
        # For the sake of simplicity, BoundEvent should be comparable
        # to [task, event_model]
        def hash; [task,event_model].hash end
        
        # If this event already happened
        def happened?; task.history.find { |_, ev| ev.class == event_model } end
    end

    class ExternalEvent
        include Event::ModelOperations
        attr_accessor :handler

        def initialize(&handler); @handler = handler end

        def emit(context); handler.call(context) if handler end
        def on(&handler)
            ##### FIXME
            # on should have the same signature than Task#on
            raise "there is already a handler defined" if @handler
            @handler = handler 
            self
        end

        attr_accessor :permanent
        def permanent!
            @permanent = true 
            self
        end
    end

    class AndEvent < ExternalEvent
        def initialize
            super
            @events = Set.new
            @waiting  = Set.new
        end

        def << (event_model)
            @events  << event_model
            @waiting << event_model
            event_model.on do |event|
                if !done? || permanent
                    @waiting.delete(event_model)
                    emit :stop if done?
                end
            end
            self
        end

        def reset; @waiting = @events.dup end
        def done?; @waiting.empty? end
        def remaining; @waiting end
        
        def to_and; self end
        def &(event_model); self << event_model end

    protected
        attr_reader :waiting
        def initialize_copy(from); @waiting = from.waiting.dup end
    end
    class OrEvent < ExternalEvent
        def initialize
            super
            @done = false
            @waiting = Set.new
        end

        def << (event_model)
            @waiting << event_model
            event_model.on do |event_model| 
                emit(event_model) if !done? || permanent
                @done = true
            end
            self
        end

        def reset; @done = false end
        def done?; @done end
        def to_or; self end
        def |(event_model); self << task end

    protected
        attr_reader :waiting
        def initialize_copy(from); @waiting = from.waiting.dup end
    end
end

