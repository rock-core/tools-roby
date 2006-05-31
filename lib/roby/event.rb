require 'set'
require 'roby/exceptions'
require 'roby/event_loop'
require 'roby/support'
require 'roby/relations/causal'
require 'roby/relations/ensured.rb'

module Roby
    class EventModelViolation < ModelViolation
	attr_reader :generator
	def initialize(generator)
	    @generator = generator
	    super()
	end
    end

    class Event
        attr_reader :generator, :context
        def initialize(generator, context)
            @generator, @context = generator, context
        end

        def model; self.class end

	def to_s; "#<Event:0x#{address.to_s(16)} generator=#{generator} model=#{model}" end
    end

    class EventGenerator
        # Generic double-dispatchers for operation on
        # bound events, based on to_and and to_or
        def |(generator)
            if generator.respond_to?(:to_or)
                generator.to_or | self
            else
                OrGenerator.new << self << generator
            end
        end
        def &(generator)
            if generator.respond_to?(:to_and)
                generator.to_and & self
            else
                AndGenerator.new << self << generator
            end
        end

        attr_enumerable(:handler, :handlers) { Array.new }

	def model
	    self.class
	end

	attr_reader :pending
	def pending?; pending != 0 end
        def initialize(controlable = nil, &control)
            @handlers = []
	    @pending  = 0

	    if controlable || control
		control = lambda { |context| emit(context) } if !control
		self.command = control
		singleton_class.class_eval { public :call }
	    end
	end

	def command=(block)
	    # Returns true if the command has been called and false otherwise
	    # The command won't be called if postpone() is called within the
	    # #calling hook
	    define_method(:call_without_propagation) do |context|
		return if pending > 0

		postponed = catch :postponed do 
		    calling(context)
		    @pending += 1

		    propagation_context(self) do
			block[context]
		    end

		    called(context)
		    nil
		end
		
		if postponed
		    postponed(context, *postponed)
		    false
		else
		    true
		end
	    end
	    @controlable = true
	end

	def call(context)
	    if gathering?
		Thread.current[:propagation][self] << [false, Thread.current[:propagation_event], context]
	    else
		initial_set = []
		first_step = gather_propagation do
		    initial_set << self if call_without_propagation(context)
		end
		propagate(first_step, initial_set)
	    end
	end
	private :call

	# Call #postpone in the #calling hook to 
	def postpone(generator, reason = nil)
	    generator.on self
	    yield
	    throw :postponed, [generator, reason]
	end
	def postponed(context, generator, reason); super if defined? super end

        # Establishes signalling and/or event handlers from this event model
        def on(*signals, &handler)
            if !signals.all? { |e| EventGenerator === e }
                raise ArgumentError, "arguments to EventGenerator#on shall be EventGenerator objects, got #{signals.inspect}" 
	    elsif bad_signal = signals.find { |e| !can_signal?(e) }
		raise EventModelViolation.new(self), "trying to establish a signal between #{self} and #{bad_signal}"
            end
	    signals.each { |sig| add_signal(sig) }

            if handler
                check_arity(handler, 1)
                self.handlers << handler
            end

            self
        end

        # If this event can signal +event+
        def can_signal?(generator); generator != self && generator.controlable?  end

	# Create a new event object for +context+
	def new(context); Event.new(self, context) end

	# If we are currently in the propagation stage
	def gathering?; !!Thread.current[:propagation] end
	def source_event; Thread.current[:propagation_event] end
	def source_generator; Thread.current[:propagation_generator] end
	# Begin a propagation stage
        def gather_propagation
            raise "nested call to #gather_propagation" if gathering?
            Thread.current[:propagation] = Hash.new { |h, k| h[k] = Array.new }
	    
            yield

	    return Thread.current[:propagation]
        ensure
            Thread.current[:propagation] = nil
        end

	# returns the value returned by the block
	def propagation_context(source)
	    raise "not in a gathering context in #fire" unless gathering?
	    event, generator = source_event, source_generator

	    if source.kind_of?(Event)
		Thread.current[:propagation_event] = source
		Thread.current[:propagation_generator] = source.generator
	    else
		Thread.current[:propagation_event] = nil
		Thread.current[:propagation_generator] = source
	    end

	    yield Thread.current[:propagation]

	ensure
	    Thread.current[:propagation_event] = event
	    Thread.current[:propagation_generator] = generator
	end
		  

	def add_signal_to_propagation(only_forward, event, signalled, context)
	    if event == signalled
		raise EventModelViolation.new(event.generator), "#{event.generator} is trying to signal itself"
	    elsif !only_forward && !event.generator.can_signal?(signalled) 
		raise EventModelViolation.new(event.generator), "trying to signal #{signalled} from #{event.generator}"
	    end

	    Thread.current[:propagation][signalled] << [only_forward, event, context]
	end
        
	# Do fire this event. It gathers the list of signals that are to
	# be propagated in the next step and calls fired()
        def fire(event)
	    propagation_context(event) do |result|
		enum_for(:each_signal).each do |signalled|
		    add_signal_to_propagation(false, event, signalled, event.context)
		end
		enum_for(:each_forwarding).each do |signalled|
		    add_signal_to_propagation(true, event, signalled, event.context)
		end

		# Since we are in a gathering context, call
		# to other objects are not done, but gathered in the 
		# :propagation TLS
		each_handler { |h| h.call(event) }
	    end

	ensure
	    # Do fire the event
	    history << [Time.now, event]
	    fired(event)
	end
        private :fire

	# raises an exception object when an event whose command has been called
	# won't be emitted (ever)
	def emit_failed(*what)
	    what, message = *what
	    what ||= EventModelViolation

	    if !message && what.respond_to?(:to_str)
		message = what.to_str
		what = EventModelViolation
	    end

	    if Class === what
		raise what.new(self), "failed to emit #{self}: #{message}"
	    else
		raise what, "failed to emit #{self}: #{message}"	
	    end
	end

	# returns true to match the behavior of #call_without_propagation
	def emit_without_propagation(context)
	    # Create the event object
	    event = new(context)
	    unless event.respond_to?(:context)
		raise TypeError, "#{event} is not a valid event object in #{self}"
	    end
	    fire(event)

	    true

	ensure
	    @pending -= 1 if @pending > 0
	end

	# Emit the event with +context+ as the new event context
	# Returns the new event object
        def emit(context)
            if gathering?
		if source_generator == self
		    emit_without_propagation(context)
		else
		    Thread.current[:propagation][self] << [true, source_event, context]
		end
		return
	    end

	    first_step = gather_propagation { emit_without_propagation(context) }
	    propagate(first_step, self)
	end

	def propagate(next_step, *initial_set)
	    # Problem with postponed: the object is included in already_seen while it
	    # has not been fired
       	    already_seen = initial_set.to_set

	    while !next_step.empty?
                next_step = gather_propagation do
                    # Call event signalled by this task
                    # Note that internal signalling does not need a #call
                    # method (hence the respond_to? check). The fact that the
                    # event can or cannot be fired is checked in #fire (using can_signal?)
		    next_step.each do |signalled, sources|
			sources.each do |emit, source, context|
			    source.generator.signalling(source, signalled) if source

			    if already_seen.include?(signalled) && !(emit && signalled.pending?)
			        Roby.debug { "#{signalled} has already been signalled" }
			        next
			    end

			    did_call = propagation_context(source) do |result|
				if !emit && signalled.controlable?
				    signalled.call_without_propagation(context) 
				else
				    signalled.emit_without_propagation(context)
				end
			    end
			    already_seen << signalled if did_call
			end
		    end
                end
            end        
	    return self
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
	def emit_on(generator, *context_override)
	    generator.add_forwarding(self)
	end

        def controlable?; @controlable end
	attribute(:history) { Array.new }
        def happened?;  !history.empty? end
        def last;       history.last end

	# An event generator is active when the current execution context may 
	# lead to its execution
	def active?(seen = Set.new)
	    if seen.include?(self)
		false
	    else
		seen << self
		each_parent_object(EventStructure::CausalLinks).find { |ev| ev.active?(seen) }
	    end
	end

        def ever
            @ever ||= EverGenerator.new(self) 
        end

	# Hook called when this event generator is called (i.e. the associated command
	# is), before the command is actually called. Think of it as a pre-call hook.
	def calling(context); super if defined? super end

	# Hook called just before the event command has been called
	def called(context); super if defined? super end

	# Hook called when this generator has been fired. +event+ is the Event object
	def fired(event); super if defined? super end

	# Hook called just before the +to+ generator is signalled 
	# by +event+, with +event+ being generated by this model
	def signalling(event, to); super if defined? super end
    end

    module EventDisplayHooks
	def calling(context)
	    puts "#{self} called with context #{context}"
	    super if defined? super
	end
	def fired(event)
	    puts "#{self}: fired #<#{event.class}: 0x#{event.address.to_s(16)}>"
	    super if defined? super
	end
	def signalling(event, to)
	    puts "#{self}: #<#{event.class}: 0x#{event.address.to_s(16)}> is signalling #{to}"
	    super if defined? super
	end
    end

    class ForwarderGenerator < EventGenerator
	attr_reader :aliases
	def initialize(*aliases)
	    super(true)

	    @aliases = Set.new
	    aliases.each { |ev| self << ev }
	end
	def controlable?; aliases.all? { |ev| ev.controlable? } end

	def <<(generator)
	    return if aliases.include?(generator)
	    aliases << generator
	    add_signal generator
	end
	def delete(generator)
	    if aliases.delete(generator)
		remove_signal(generator)
		generator
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
            event = base.last.last
            raise EventModelViolation.new(self), "cannot change the context of an EverEvent" if context && context != event.context
            event
        end

        def initialize(base)
            @base = base
            if base.controlable?
		super { base.call(nil) unless base.happened? }
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
            @events	= Set.new
            @waiting	= Set.new
            super()
        end

        attr_accessor :permanent
        def permanent!; self.permanent = true end

        def << (generator)
            @events  << generator
            @waiting << generator
            generator.on do |event|
		if !done? || permanent
		    @waiting.delete(generator)
		    emit(nil) if done?
		end
            end

            generator.add_causal_link self
            
            self
        end

        def reset; @waiting = @events.dup end
        def done?; @waiting.empty? end
        def remaining; @waiting end
        
        def to_and; self end
        def &(generator); self << generator end

	def active?(seen); each_parent_object(EventStructure::CausalLink).all? { |obj| obj.active?(seen) } end

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

        def << (generator)
            @waiting << generator
            generator.on do |event| 
                @done << event
                emit(nil) if @done.size == 1 || permanent
            end

            generator.add_causal_link self
            
            self
        end

        def reset; @done.clear end
        def done?; !(@done.empty?) end
        def to_or; self end
        def |(generator); self << generator end

        def new(context = nil)
            event = @done.last
            raise EventModelViolation.new(self), "cannot change the context of a OrGenerator" if context && context != event.context
            event
        end

    protected
        attr_reader :waiting
        def initialize_copy(from); @waiting = from.waiting.dup end
    end


    module Temporal
	def until(generator)
	    Until.new(self, generator)
	end
	
	INVERSE = {
	    :on => lambda do |generator, *args|
		block = args.pop
		generator.handlers.delete(block)
		args.each { |sig| generator.remove_signal(sig) }
	    end
	}
		
	class Until
	    attr_reader :generator
	    def initialize(generator, limit)
		limit.on(&self.method(:revert))
		@generator = generator
		@revert = []
	    end

	    def method_missing(name, *args, &block)
		if !generator.respond_to?(name)
		    super
		elsif inverse = INVERSE[name]
		    generator.send(name, *args, &block)

		    args << block
		    @revert.unshift [inverse, args]
		else
		    raise NoMethodError, "#{name} is defined in #{name}, but no inverse function exists for it"
		end
	    end

	    def revert(context)
		@revert.each do |invert, args|
		    invert.call(generator, *args)
		end
		@revert.clear
	    end
	    private :revert
	end
    end

    EventGenerator.include Temporal
end

