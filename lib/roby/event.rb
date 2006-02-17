require 'set'
require 'roby/support'

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
            @task, @context = task, context
        end

        def model; self.class end

        # If the event model defines a controlable event
        # By default, an event is controlable if the model
        # responds to #call
        def self.controlable?; respond_to?(:call) end
        # If the event is controlable
        def controlable?; self.class.controlable? end
        # If the event model defines a terminal event
        def self.terminal?; @terminal end
        # If the event is terminal
        def terminal?; self.class.terminal? end
        # The event symbol
        def self.symbol; @symbol end
        # The event symbol
        def symbol; self.class.symbol end

        # A list of event handlers attached to this model
        class_inherited_enumerable(:handler, :handlers) { Array.new }
        # A list of event signals attached to this model
        class_inherited_enumerable(:signal, :signals) { Array.new }

        class << self
            def on(*signals, &handler)
                self.signals  += signals
                self.handlers << handler if handler
            end
        end
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
    # The Task/BoundEventModel/Event relationship is 
    # comparable to the Class/UnboundMethod/Method one:
    # * a Task object is a model for a task, a Class in a model for an object
    # * an Event object is a model for an event instance (the instance being unspecified), 
    #   an UnboundMethod is a model for an instance method
    # * a BoundEvent object represents a particular event model 
    #   *bound* to a particular task instance,
    #   a Method object represents a particular method bound to a particular object
    class BoundEventModel
        include Event::ModelOperations
        attr_reader :task, :event_model
        def initialize(task, event_model)
            @task, @event_model = task, event_model
            @handlers, @signals = [], []

            if event_model.respond_to?(:call)
                def call(context)
                    event_model.call(task, context) 
                end
            end
        end

        attr_enumerable(:handler, :handlers) { Array.new }
        attr_enumerable(:signal, :signals) { Array.new }
        # Establishes signalling and/or event handlers from this event model
        def on(*signals, &handler)
            unless signals.all? { |e| BoundEventModel === e }
                raise ArgumentError, "arguments to BoundEventModel#on shall be bound event models, got #{signals.inspect}" 
            end
            self.signals |= signals

            if handler
                check_arity(handler, 1)
                self.handlers << handler
                task.added_event_handler(self, handler)
            end
        end

        PropagationResult = Struct.new(:commands, :handlers)
        class PropagationResult
            def |(other)
                PropagationResult.new self.commands | other.commands, self.handlers | other.handlers
            end
        end

        # Do event propagation. Return an array of [event, [handlers]] pair
        # of the fired being fired in the propagation and the handlers 
        # that should be called
        def propagate(context)
            if event_model.command_handler
                result = PropagationResult.new [], []
                result.commands = [[ self, context ]]
                return result
            else
                return fire(context)
            end
        end
        def fire(context)
            event = new(context)
            result = task.fire_event(event) || PropagationResult.new([], [])

            # Propagate model signals
            result = event_model.enum_for(:each_signal).inject(result) do |result, signalled|
                # we *can* call propagate event on non-controlable events (this is an acceptable 
                # behaviour for internal signals). Use send to go around the private protection
                # on propagate
                result | task.event(signalled).propagate(context)
            end

            result = enum_for(:each_signal).inject(result) do |result, signalled|
                unless signalled.controlable? || signalled.task == task
                    raise TaskModelViolation, "trying to signal a non-controlable event"
                end
                result | signalled.propagate(context)
            end
            result.handlers << [ event, handlers ]
            result.handlers << [ event, event_model.enum_for(:each_handler).to_a ]

            return result
        end
        protected :propagate, :fire

        @@gather_emit = nil
        def gather_emit
            @@gather_emit = PropagationResult.new([], [])
            yield
            unless @@gather_emit.commands.empty? && @@gather_emit.handlers.empty?
                return @@gather_emit
            end
        ensure
            @@gather_emit = nil
        end

        def emit(context)
            result = fire(context)
            if @@gather_emit
                @@gather_emit |= result
                return
            end

            while result
                # Gather all emit's needed by the event handlers and event commands
                new_result = gather_emit do
                    # Call event handlers
                    result.handlers.each do |event, event_handlers|
                        task = event.task
                        event_handlers.each do |handler|
                            if task.before_calling_handler(event, handler)
                                handler.call(event) 
                            end
                            task.after_calling_handler(event, handler)
                        end
                    end

                    # Call event commands
                    result.commands.each do |bound_event, context|
                        bound_event.call(context)
                    end
                end
                result = new_result
            end
        end

        def controlable?; event_model.controlable? end
        def terminal?;    event_model.terminal? end
        def symbol;       event_model.symbol end
        def new(context); event_model.new(task, context) end

        # If this event already happened
        def happened?; task.history.find { |_, ev| ev.class == event_model } end
    end

    # Base class for events that are not bound to a particular task
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

