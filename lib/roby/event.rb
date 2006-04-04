require 'set'
require 'roby/exceptions'
require 'roby/event_loop'
require 'roby/support'
require 'roby/relations/causal'
require 'roby/relations/ensured.rb'

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

        def initialize(controlable = nil, &control)
            @handlers = []

	    @controlable = controlable
	    if controlable || control
		control = lambda { |context| emit(context) } if !control
		define_method(:call) do |context|
		    catch :filtered do 
			calling(context)
			control[context]
		    end
		end
	    end
        end

        # Establishes signalling and/or event handlers from this event model
        def on(*signals, &handler)
            unless signals.all? { |e| EventGenerator === e }
                raise ArgumentError, "arguments to EventGenerator#on shall be EventGenerator objects, got #{signals.inspect}" 
            end
	    signals.each { |sig| add_signal(sig) }

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

	def new(context); Event.new(context) end

	def gathering?; Thread.current[:propagated_events] end
        def gather_emit
            raise "nested call to #gather_emit" if gathering?
            Thread.current[:propagated_events] = PropagationResult.new
            yield
	    gathered = Thread.current[:propagated_events]
            unless gathered.events.empty? && gathered.handlers.empty?
                return gathered
            end
        ensure
            Thread.current[:propagated_events] = nil
        end
        
        def fire(event)
            result = PropagationResult.new
            result.events   |= enum_for(:each_signal).to_a
            result.handlers << [ event, handlers ]

            if bad_event = result.events.find { |ev| !can_signal?(ev) }
                raise ModelViolation, "trying to signal #{bad_event} from #{self}"
            end

	    history << [Time.now, event]
	    fired(event)

            return result
        end
        private :fire

        def emit(context)
            event   = new(context)
            result  = fire(event)
            if Thread.current[:propagated_events]
		Thread.current[:propagated_events] |= result
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

	# call-seq:
	#   emit_on event, context  => self
	#   emit_on event	    => self
	#   
	# Call #emit (bypassing any command) when +event+ is fired. If +context+
	# is not given, it forwards the context of the fired +event+
	#
	# This method is equivalent to
	#
	#   event.on { |context| self.emit(context) }
	#   event.add_causal_link self
	def emit_on(event, *context_override)
	    event.on do |context| 
		context = *context_override unless context_override.empty?
		emit(context) 
	    end
	    event.add_causal_link self
	end

        def controlable?; @controlable end
	attribute(:history) { Array.new }
        def happened?;  !history.empty? end
        def last;       history.last end

        def ever
            @ever ||= EverGenerator.new(self) 
        end

	# Hook called when this event generator is called (i.e. the associated command
	# is), before the command is actually called. Think of it as a pre-call hook.
	def calling(context)
	    super if defined? super
	end

	# Hook called when an event has been fired
	def fired(event)
	    super if defined? super
	end
    end

    class ForwarderGenerator < EventGenerator
	attr_reader :aliases
	def initialize(*aliases)
	    @aliases = aliases.to_set

	    super() do |context|
		emit(context)
	    end
	end
	def controlable?; aliases.all? { |ev| ev.controlable? } end

	def new(context)
	    Event.new(context)
	end
	
	def <<(event)
	    return if aliases.include?(event)
	    aliases << event
	    add_signal event

	    if controlable? && !respond_to?(:call)
		singleton_class.class_eval { public :call }
	    elsif !controlable? && respond_to?(:call)
		singleton_class.class_eval { private :call }
	    end
	end
	def delete(event)
	    if aliases.delete(event)
		remove_signal(event)
		event
	    end
	end
    end

    class EverGenerator < EventGenerator
        attr_reader :base

        class << self
	    # The list of ever events to generate on next event loop
            attribute(:pending) { Array.new }
        end
        Roby.event_processing << lambda do
            pending.each { |ev| ev.emit(nil) }
            pending.clear
        end

        def new(context)
            event = base.last
            raise ModelViolation, "cannot change the context of an EverEvent" if context && context != event.context
            event
        end

        def initialize(base)
            @base = base
            if base.controlable?
		super { base.call unless base.happened? }
                self.add_causal_link base
	    else
		super(false)
            end
            
            if base.happened?
                EverGenerator.pending << self
            else
		emit_on(base, nil)
            end
        end
    end

    class AndGenerator < EventGenerator
        def initialize
            @events = Set.new
            @waiting  = Set.new
            super()
	    raise unless handlers
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

            event_model.add_causal_link self
            
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
            super()
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

            event.add_causal_link self
            
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

