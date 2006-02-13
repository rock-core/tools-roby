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

    # An event bound to a particular task instance
    # The Task/BoundEvent/Event relationship is 
    # comparable to the Class/UnboundMethod/Method one:
    # * a Task object is a model for a task, a Class in a model for an object
    # * an Event object is a model for an event instance (the instance being unspecified), 
    #   an UnboundMethod is a model for an instance method
    # * a BoundEvent object represents a particular event type *bound* to a particular task instance,
    #   a Method object represents a particular method bound to a particular object
    class BoundEvent
        attr_reader :task, :event
        def initialize(task, event); @task, @event = task, event end
        def emit(context); task.emit(event, context) end
        def on(*args, &proc); task.on(event, *args, &proc) end

        # For the sake of simplicity, BoundEvent should be comparable
        # to [task, event_model]
        def ==(description); [task, event] == description end
        # For the sake of simplicity, BoundEvent should be comparable
        # to [task, event_model]
        def hash; [task,event].hash end
    end

    module EventAggregator
        # Generic double-dispatchers for operation on
        # bound events, based on to_and and to_or
        module Operations
            def |(event)
                if event.respond_to?(:to_or)
                    event.to_or | self
                else
                    Or.new << self << event
                end
            end
            def &(event)
                if event.respond_to?(:to_and)
                    event.to_and & self
                else
                    And.new << self << event
                end
            end
        end

        class Aggregator
            include Operations
            attr_accessor :handler
            def initialize(&handler)
                @handler = handler
            end

            def emit(context); handler.call(context) if handler end
            def on(&handler)
                @handler = handler 
                self
            end

            attr_accessor :permanent
            def permanent!
                @permanent = true 
                self
            end
        end

        class And < Aggregator
            def initialize
                super()
                @events = Set.new
                @waiting  = Set.new
            end

            def << (event_description)
                @events  << event_description
                @waiting << event_description
                event_description.on do |event|
                    if !done? || permanent
                        @waiting.delete(event_description)
                        emit :stop if done?
                    end
                end
                self
            end

            def reset; @waiting = @events.dup end
            def done?; @waiting.empty? end
            def remaining; @waiting end
            
            def to_and; self end
            def &(event); self << event end

        protected
            attr_reader :waiting
            def initialize_copy(from); @waiting = from.waiting.dup end
        end
        class Or < Aggregator
            def initialize
                super()
                @done = false
                @waiting = Set.new
            end

            def << (event_description)
                @waiting << event_description
                event_description.on do |event| 
                    emit(event) if !done? || permanent
                    @done = true
                end
                self
            end

            def reset; @done = false end
            def done?; @done end
            def to_or; self end
            def |(event); self << task end

        protected
            attr_reader :waiting
            def initialize_copy(from); @waiting = from.waiting.dup end
        end
    end
    class BoundEvent
        include EventAggregator::Operations
    end
end

