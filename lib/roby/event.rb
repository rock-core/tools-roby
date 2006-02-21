require 'set'
require 'roby/event_loop'
require 'roby/support'

module Roby
    class Event
        attr_reader :context
        def initialize(context)
            @context = context
        end

        def model; self.class end

    end

    
    class EventGenerator
        # Generic double-dispatchers for operation on
        # bound events, based on to_and and to_or
        def |(event_model)
            if event_model.respond_to?(:to_or)
                event_model.to_or | self
            else
                OrGenerator.new << self << event_model
            end
        end
        def &(event_model)
            if event_model.respond_to?(:to_and)
                event_model.to_and & self
            else
                AndGenerator.new << self << event_model
            end
        end

        attr_enumerable(:handler, :handlers) { Array.new }
        attr_enumerable(:signal, :signals) { Array.new }

        def initialize
            @handlers, @signals = [], []
        end

        # Establishes signalling and/or event handlers from this event model
        def on(*signals, &handler)
            unless signals.all? { |e| EventGenerator === e }
                raise ArgumentError, "arguments to EventGenerator#on shall be EventGenerator objects, got #{signals.inspect}" 
            end
            self.signals |= signals

            if handler
                check_arity(handler, 1)
                self.handlers << handler
            end

            self
        end

        class PropagationResult
            attr_accessor :events, :handlers
            def initialize(events = [], handlers = [])
                @events, @handlers = events, handlers 
            end
            def |(other)
                PropagationResult.new self.events | other.events, self.handlers | other.handlers
            end
        end

        # If this event can signal +event+
        def can_signal?(event); event.controlable?  end


        @@gather_emit = nil
        def gather_emit
            raise "nested calls to #gather_emit" if @@gather_emit
            @@gather_emit = PropagationResult.new
            yield
            unless @@gather_emit.events.empty? && @@gather_emit.handlers.empty?
                return @@gather_emit
            end
        ensure
            @@gather_emit = nil
        end
        
        def fire(event)
            @happened = event

            result = PropagationResult.new
            result.events   |= enum_for(:each_signal).to_a
            result.handlers << [ event, handlers ]

            if bad_event = result.events.find { |ev| !can_signal?(ev) }
                raise TaskModelViolation, "trying to signal #{bad_event} from #{self}"
            end

            return result
        end
        private :fire

        def emit(context)
            event   = new(context)
            result  = fire(event)
            if @@gather_emit
                @@gather_emit |= result
                return
            end

            while result
                new_result = gather_emit do
                    # Call event signalled by this task
                    # Note that internal signalling does not need a #call
                    # method (hence the respond_to? check). The fact that the
                    # event can or cannot be fired is checked in #fire (using can_signal?)
                    result.events.each { |event| 
                        if event.respond_to?(:call)
                            event.call(context) 
                        else
                            event.emit(context)
                        end
                    }

                    # Call event handlers
                    result.handlers.each do |event, event_handlers|
                        event_handlers.each do |handler|
                            handler.call(event) 
                        end
                    end
                end
                result = new_result
            end        
        end

        def controlable?; false end
        def happened?;  !!@happened end
        def last;       @happened end

        def ever; EverGenerator.new(self) end
    end

    class EverGenerator < EventGenerator
        attr_reader :base

        @pending = Array.new
        class << self
            attr_reader :pending
        end
        Roby.event_processing << lambda do
            pending.each { |ev| ev.emit(nil) }
            pending.clear
        end

        def new(context = nil)
            event = base.last
            raise ModelViolation, "cannot change the context of an EverEvent" if context && context != event.context
            event
        end

        def initialize(base, &handler)
            @base = base
            super(&handler)

            if base.controlable?
                def self.call
                    base.call unless base.happened?
                end
            elsif base.happened?
                EverGenerator.pending << self
            else
                base.on { self.emit }
            end
        end
    end

    class AndGenerator < EventGenerator
        def initialize
            super
            @events = Set.new
            @waiting  = Set.new
        end

        attr_accessor :permanent
        def permanent!; self.permanent = true end

        def << (event_model)
            @events  << event_model
            @waiting << event_model
            event_model.on do |event|
                if !done? || permanent
                    @waiting.delete(event_model)
                    emit(nil) if done?
                end
            end
            self
        end

        def reset; @waiting = @events.dup end
        def done?; @waiting.empty? end
        def remaining; @waiting end
        
        def to_and; self end
        def &(event_model); self << event_model end

        def new(context); Event.new(context) end

    protected
        attr_reader :waiting
        def initialize_copy(from); @waiting = from.waiting.dup end
    end

    class OrGenerator < EventGenerator
        def initialize
            super
            @done       = []
            @waiting    = Set.new
        end

        attr_accessor :permanent
        def permanent!; self.permanent = true end

        def << (event)
            @waiting << event
            event.on do |event_model| 
                emit(nil) if !done? || permanent
                @done << event
            end
            self
        end

        def reset; @done.clear end
        def done?; !(@done.empty?) end
        def to_or; self end
        def |(event_model); self << task end

        def new(context = nil)
            event = @done.last
            raise ModelViolation, "cannot change the context of a OrGenerator" if context && context != event.context
            event
        end

    protected
        attr_reader :waiting
        def initialize_copy(from); @waiting = from.waiting.dup end
    end
end

