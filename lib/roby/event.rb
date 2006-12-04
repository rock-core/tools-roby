require 'set'
require 'roby/plan-object'
require 'roby/exceptions'
require 'roby/relations'

module Roby
    class EventModelViolation < ModelViolation
	attr_reader :generator
	def initialize(generator)
	    raise TypeError, "not an event" unless generator.respond_to?(:to_event)
	    @generator = generator.to_event
	    super()
	end
    end

    class EventNotExecutable < EventModelViolation; end
    class EventCanceled < EventModelViolation; end
    class EventPreconditionFailed < EventModelViolation; end

    class Event
	attr_reader :generator

	def initialize(generator, propagation_id, context)
	    raise ArgumentError, "bad value for propagation_id: #{propagation_id}" unless propagation_id
	    @generator, @propagation_id, @context = generator, propagation_id, context
	end

	attr_accessor :propagation_id, :context
	protected :propagation_id=, :context=

	# To be used in the event generators ::new methods, when we need to reemit
	# an event while changing its 
	def reemit(new_id, new_context = nil)
	    if propagation_id != new_id || (new_context && new_context != context)
		new_event = self.dup
		new_event.propagation_id = new_id
		new_event.context = new_context
		new_event
	    else
		self
	    end
	end

	def name; model.name end
	def model; self.class end
	def inspect; "#<#{model.to_s}:0x#{address.to_s(16)} generator=#{generator} model=#{model}" end
    end

    # EventGenerator objects are the objects which manage the event generation
    # process (propagation, event creation, ...). They can be combined logically
    # using & and |.
    #
    # == Standard relations
    # - signals: calls the *command* of an event when this generator emits
    # - forwardings: *emits* another event when this generator emits
    #
    # In the first case, #can_signal? is checked to ensure that the target
    # event can be called. In the forwarding case, not checks are done
    #
    class EventGenerator < PlanObject
	# How to handle this event during propagation
	#   * nil (the default): call only once in a propagation cycle
	#   * :always_call: always call, event if it has already been called in this cycle
	attr_accessor :propagation_mode

	attr_writer :executable
	def executable?; @executable end

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

	def model; self.class end
	def name; model.name end

	attr_reader :pending
	def pending?; pending != 0 end
	def initialize(controlable = nil, &control)
	    @preconditions = []
	    @handlers = []
	    @pending  = 0
	    @executable = true

	    super() if defined? super

	    if controlable || control
		self.command = (control || lambda { |context| emit(context) })
	    end
	end

	# Sets a command proc for this event generator. Sets controlable to true
	def command=(block)
	    # Returns true if the command has been called and false otherwise
	    # The command won't be called if postpone() is called within the
	    # #calling hook
	    singleton_class.send(:define_method, :call_without_propagation) do |context|
		postponed = catch :postponed do 
		    calling(context)
		    @pending += 1

		    Propagation.propagation_context([self]) do
			Propagation.gather_exceptions(self) { block[context] }
		    end
		    false
		end
		called(context)

		if postponed
		    postponed(context, *postponed)
		    false
		else
		    true
		end
	    end
	    @controlable = true
	    singleton_class.class_eval { public :call }
	end

	# Call the command associated with self. Note that an event might be
	# non-controlable and respond to the :call message. Controlability must
	# be checked using #controlable?
	def call(context = nil)
	    if !controlable?
		raise EventModelViolation.new(self), "#call called on a non-controlable event"
	    elsif !executable?
		raise EventNotExecutable.new(self), "#call called on #{self} which is non-executable event"
	    end

	    if Propagation.gathering?
		Propagation.add_event_propagation(false, Propagation.source_events, self, context)
	    else
		exceptions = Propagation.propagate_events do |initial_set|
		    initial_set << self if call_without_propagation(context)
		end
		exceptions.each { |e| raise e.exception }
	    end
	end
	private :call

	# Establishes signalling and/or event handlers from this event model
	def on(*signals, &handler)
	    if bad_signal = signals.find { |e| !can_signal?(e) }
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

	def to_event; self end

	# Returns the set of events directly related to this one
	def related_events(result = nil); related_objects(nil, result) end
	# Returns the set of tasks directly related to this event
	def related_tasks(result = nil)
	    result ||= ValueSet.new
	    related_events.each do |ev| 
		if ev.respond_to?(:task)
		    result << ev.task
		end
	    end
	    result
	end

	# Create a new event object for +context+
	def new(context); Event.new(self, Propagation.propagation_id, context) end

	def add_propagation(only_forward, event, signalled, context)
	    if self == signalled
		raise EventModelViolation.new(self), "#{self} is trying to signal itself"
	    elsif !only_forward && !can_signal?(signalled) 
		# NOTE: the can_signal? test here is NOT redundant with the test in #on, 
		# since here we validate calls done in event handlers too
		raise EventModelViolation.new(self), "trying to signal #{signalled} from #{self}"
	    end

	    Propagation.add_event_propagation(only_forward, [event], signalled, context)
	end
	private :add_propagation

	# Do fire this event. It gathers the list of signals that are to
	# be propagated in the next step and calls fired()
	#
	# This method is always called in a propagation context
	def fire(event)
	    Propagation.propagation_context([event]) do |result|
		each_signal do |signalled|
		    add_propagation(false, event, signalled, event.context)
		end
		each_forwarding do |signalled|
		    add_propagation(true, event, signalled, event.context)
		end

		# Since we are in a gathering context, call
		# to other objects are not done, but gathered in the 
		# :propagation TLS
		each_handler do |h| 
		    Propagation.gather_exceptions(self) { h.call(event) }
		end
	    end

	ensure
	    # Do fire the event
	    history << [Time.now, event]
	    fired(event)
	end
	private :fire

	# Raises an exception object when an event whose command has been called
	# won't be emitted (ever)
	def emit_failed(*what)
	    @pending -= 1

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

	# Emits the event regardless of wether we are in a propagation context or not
	# Returns true to match the behavior of #call_without_propagation
	def emit_without_propagation(context)
	    if !executable?
		raise EventNotExecutable.new(self), "#emit called on #{self} which is not executable"
	    end

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
	def emit(context)
	    if !executable?
		raise EventNotExecutable.new(self), "#emit called on #{self} which is not executable"
	    end

	    if Propagation.gathering?
		if Propagation.source_generators.include?(self)
		    # WTF ? an event calling itself ? I remember that there is a good 
		    # reason for that, but can't recall which. That sucks.
		    emit_without_propagation(context)
		else
		    Propagation.add_event_propagation(true, Propagation.source_events, self, context)
		end
	    else
		exceptions = Propagation.propagate_events do |initial_set|
		    initial_set << self
		    emit_without_propagation(context)
		end
		exceptions.each { |e| raise e.exception }
	    end
	end

	# call-seq:
	#   emit_on event	    => self
	#   
	# Call #emit (bypassing any command) when +event+ is fired.
	# This method is equivalent to
	#
	#   self.add_forwarding(self)
	def emit_on(generator)
	    generator.add_forwarding(self)
	end

	def controlable?; @controlable end
	attribute(:history) { Array.new }
	def happened?(strict = true)
	    !history.empty? || 
		(!strict && Propagation.gathering? && Propagation.pending_event?(self))
	end
	def last
	    return if history.empty?
	    history.last[1] 
	end

	def precondition(reason = nil, &block)
	    @preconditions << [reason, block]
	end
	def each_precondition; @preconditions.each { |o| yield(o) } end

	# Call #postpone in the #calling hook to announce that
	# the event being called is not to be called now, but will
	# be called back when +generator+ is emitted.
	#
	# A reason string can be provided for debugging purposes
	def postpone(generator, reason = nil)
	    generator.on self
	    yield
	    throw :postponed, [generator, reason]
	end
	def postponed(context, generator, reason); super if defined? super end	

	# Call this method in the #calling hook to avoid calling
	# the event command. This raises a PreconditionFailed
	# exception
	def cancel(reason = nil)
	    raise EventCanceled.new(self)
	end

	# Hook called when this event generator is called (i.e. the associated command
	# is), before the command is actually called. Think of it as a pre-call hook.
	def calling(context)
	    super if defined? super 
	    each_precondition do |reason, block|
		result = begin
			     block.call(self, context)
			 rescue EventPreconditionFailed => e
			     e.generator = self
			     raise
			 end

		if !result
		    raise EventPreconditionFailed.new(self), "precondition #{reason} failed"
		end
	    end
	end

	# Hook called just before the event command has been called
	def called(context); super if defined? super end

	# Hook called when this generator has been fired. +event+ is the Event object
	def fired(event); super if defined? super end

	# Hook called just before the +to+ generator is signalled 
	# by +event+, with +event+ being generated by this model
	def signalling(event, to); super if defined? super end

	include DirectedRelationSupport
    end

    EventStructure  = RelationSpace(EventGenerator)

    module EventDisplayHooks
	def calling(context)
	    puts "#{self} called with context #{context}"
	    super if defined? super
	end
	def fired(event)
	    puts "#{self}: fired #<#{event.model.to_s}:0x#{event.address.to_s(16)}>"
	    super if defined? super
	end
	def signalling(event, to)
	    puts "#{self}: #<#{event.model.to_s}:0x#{event.address.to_s(16)}> is signalling #{to}"
	    super if defined? super
	end
    end

    # Slow down the event propagation (for debugging purposes)
    module SlowEventPropagation
	def calling(context)
	    super if defined? super
	    sleep(0.1)
	end

	def fired(event)
	    super if defined? super
	    sleep(0.1)
	end

	def signalling(event, to)
	    super if defined? super
	    sleep(0.1)
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

    class AndGenerator < EventGenerator
	def initialize
	    super(&method(:emit_if_achieved))
	    self.propagation_mode = :always_call
	    @events = Hash.new
	end

	def emit_if_achieved(context)
	    return if happened?
	    each_parent_object(EventStructure::Signal) do |source|
		return if @events[source] == source.last
	    end
	    emit(nil)
	end
	
	def added_parent_object(parent, type, info)
	    super if defined? super
	    return unless type == EventStructure::Signal
	    @events[parent] = parent.last
	end
	def removed_parent_object(parent, type, info)
	    super if defined? super
	    return unless type == EventStructure::Signal
	    @events.delete(parent)
	end

	def events;  enum_for(:each_parent_object, EventStructure::Signal).to_a end
	def waiting; enum_for(:each_parent_object, EventStructure::Signal).find_all { |ev| @events[ev] == ev.last } end

	def << (generator)
	    generator.add_signal self
	    self
	end

	def to_and; self end
	def &(generator); self << generator end
    end

    class OrGenerator < EventGenerator
	def initialize
	    super(&method(:emit_if_first))
	end

	def emit_if_first(context)
	    return if happened?
	    emit(context)
	end

	def << (generator)
	    generator.add_signal self
	    self
	end

	def to_or; self end
	def |(generator); self << generator end
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

require 'roby/relations/causal'
require 'roby/relations/ensured'
require 'roby/propagation'

