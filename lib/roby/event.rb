require 'roby/plan-object'
require 'roby/exceptions'
require 'set'

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

	def initialize(generator, propagation_id, context, time = Time.now)
	    @generator, @propagation_id, @context, @time = generator, propagation_id, context, time
	end

	attr_accessor :propagation_id, :context, :time
	protected :propagation_id=, :context=, :time=

	# To be used in the event generators ::new methods, when we need to reemit
	# an event while changing its 
	def reemit(new_id, new_context = nil)
	    if propagation_id != new_id || (new_context && new_context != context)
		new_event = self.dup
		new_event.propagation_id = new_id
		new_event.context = new_context
		new_event.time = Time.now
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
    # process (propagation, event creation, ...). They can be combined
    # logically using & and |.
    #
    # === Standard relations
    # - signals: calls the *command* of an event when this generator emits
    # - forwardings: *emits* another event when this generator emits
    #
    # In the first case, #can_signal? is checked to ensure that the target
    # event can be called. In the forwarding case, not checks are done
    #
    # === Hooks
    # The following hooks are defined:
    # * #postponed
    # * #calling
    # * #called
    # * #fired
    # * #signalling
    # * #forwarding
    #
    class EventGenerator < PlanObject
	# How to handle this event during propagation
	# * nil (the default): call only once in a propagation cycle
	# * :always_call: always call, event if it has already been called in this cycle
	attr_accessor :propagation_mode

	attr_writer :executable
	# True if this event is executable. A non-executable event cannot be
	# called even if it is controlable
	def executable?; @executable end

	# Creates a new Event generator which is emitted as soon as one of this
	# object and +generator+ is emitted
	def |(generator)
	    OrGenerator.new << self << generator
	end

	# Creates a AndGenerator object which is emitted when both this object
	# and +generator+ are emitted
	def &(generator)
	    AndGenerator.new << self << generator
	end

	attr_enumerable(:handler, :handlers) { Array.new }

	def model; self.class end
	# The model name
	def name; model.name end
	# The count of command calls that have not a corresponding emission
	attr_reader :pending
	# True if this event has been called but is not emitted yet
	def pending?; pending end

	# call-seq:
	#   EventGenerator.new
	#   EventGenerator.new(false)
	#   EventGenerator.new(true)
	#   EventGenerator.new { |event| ... }
	#
	# Create a new event generator. If a block is given, the event is
	# controlable and the block is its command. If a +true+ argument is
	# given, the event is controlable and is 'pass-through': it is emitted
	# as soon as its command is called. If no argument is given (or a
	# +false+ argument), then it is not controlable
	def initialize(controlable = nil, &control)
	    @preconditions = []
	    @handlers = []
	    @pending  = false
	    @executable = true

	    super() if defined? super

	    if controlable || control
		self.command = (control || method(:emit))
	    end
	end

	# The current command block
	attr_reader :command

	# Sets a command proc for this event generator. Sets controlable to true
	def command=(block)
	    old = @command
	    @command = block
	    if !block ^ !old
		if block then singleton_class.class_eval { public :call }
		else singleton_class.class_eval { private :call }
		end
	    end
	end
	
	# True if this event is controlable
	def controlable?; !!@command end

	# Returns true if the command has been called and false otherwise
	# The command won't be called if postpone() is called within the
	# #calling hook
	def call_without_propagation(context) # :nodoc:
	    error = false
	    postponed = catch :postponed do 
		calling(context)
		@pending = true

		Propagation.propagation_context([self]) do
		    error = Propagation.gather_exceptions(self) { command[context] }
		end

		false
	    end

	    if error
		@pending = false
		false
	    elsif postponed
		@pending = false
		postponed(context, *postponed)
		false
	    else
		called(context)
		true
	    end
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
		Propagation.add_event_propagation(false, Propagation.source_events, self, context, nil)
	    else
		errors = Propagation.propagate_events do |initial_set|
		    initial_set << self if call_without_propagation(context)
		end
		errors.each { |e| raise e.exception }
	    end
	end
	private :call

	# Establishes signalling and/or event handlers from this event model.
	# If +time+ is non-nil, it is a delay (in seconds) which must pass
	# between the time this event is emitted and the time +signal+ is
	# called
	def on(signal = nil, time = nil, &handler)
	    if signal
		if !can_signal?(signal)
		    raise EventModelViolation.new(self), "trying to establish a signal between #{self} and #{signal}"
		end
		add_signal(signal, time)
	    end

	    if handler
		check_arity(handler, 1)
		self.handlers << handler
	    end

	    self
	end

	# Adds a signal from this event to +generator+
	def signal(generator); on(generator) end
	# Forward this event to +generator+
	def forward(generator); generator.emit_on self end
	# Returns an event which is emitted +seconds+ seconds after this one
	def delay(seconds)
	    if seconds == 0 then self
	    else
		ev = EventGenerator.new(true)
		on(ev, :delay => seconds)
		ev
	    end
	end

	# Signal the +signal+ event the first time this event is emitted.  If
	# +time+ is non-nil, delay the signalling. +handler+ is an optional
	# event handler to be called once as well.
	def signal_once(signal = nil, time = nil, &handler)
	    on(signal, time) { remove_signal(signal) }
	end

	# If this event can signal +generator+
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
	def new(context); Event.new(self, Propagation.propagation_id, context, Time.now) end

	def add_propagation(only_forward, event, signalled, context, timespec) # :nodoc:
	    if self == signalled
		raise EventModelViolation.new(self), "#{self} is trying to signal itself"
	    elsif !only_forward && !can_signal?(signalled) 
		# NOTE: the can_signal? test here is NOT redundant with the test in #on, 
		# since here we validate calls done in event handlers too
		raise EventModelViolation.new(self), "trying to signal #{signalled} from #{self}"
	    end

	    Propagation.add_event_propagation(only_forward, [event], signalled, context, timespec)
	end
	private :add_propagation

	# Do fire this event. It gathers the list of signals that are to
	# be propagated in the next step and calls fired()
	#
	# This method is always called in a propagation context
	def fire(event)
	    Propagation.propagation_context([event]) do |result|
		each_signal do |signalled|
		    add_propagation(false, event, signalled, event.context, (self[signalled, EventStructure::Signal] rescue nil))
		end
		each_forwarding do |signalled|
		    add_propagation(true, event, signalled, event.context, (self[signalled, EventStructure::Forwarding] rescue nil))
		end

		fired(event)

		# Since we are in a gathering context, call
		# to other objects are not done, but gathered in the 
		# :propagation TLS
		each_handler do |h| 
		    Propagation.gather_exceptions(self) { h.call(event) }
		end
	    end
	end
	private :fire

	# Raises an exception object when an event whose command has been called
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

	ensure
	    @pending = false
	end

	# Emits the event regardless of wether we are in a propagation context or not
	# Returns true to match the behavior of #call_without_propagation
	def emit_without_propagation(context) # :nodoc:
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
	    @pending = false
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
		    Propagation.add_event_propagation(true, Propagation.source_events, self, context, nil)
		end
	    else
		errors = Propagation.propagate_events do |initial_set|
		    initial_set << self
		    emit_without_propagation(context)
		end
		errors.each { |e| raise e.exception }
	    end
	end

	# call-seq:
	#   emit_on(event)	    => self
	#   
	# Call #emit (bypassing any command) when +event+ is fired.
	# This method is equivalent to
	#
	#   self.add_forwarding(self)
	def emit_on(generator, timespec = nil)
	    generator.add_forwarding(self, timespec)
	    self
	end

	# A [time, event] array of past event emitted by this object
	attribute(:history) { Array.new }
	# True if this event has been emitted once.
	def happened?; !history.empty? end
	# Last event to have been emitted by this generator
	def last; history.last end

	# Defines a precondition handler for this event. Precondition handlers
	# are when #call is called. If the handler returns false, the calling
	# is aborted by a PreconditionFailed exception
	def precondition(reason = nil, &block)
	    @preconditions << [reason, block]
	end
	# Yields all precondition handlers defined for this generator
	def each_precondition # :yield:reason, block
	    @preconditions.each { |o| yield(o) } 
	end

	# Call #postpone in #calling to announce that the event should not be
	# called now, but should be called back when +generator+ is emitted
	#
	# A reason string can be provided for debugging purposes
	def postpone(generator, reason = nil)
	    generator.on self
	    yield if block_given?
	    throw :postponed, [generator, reason]
	end
	# Hook called when the event has been postponed. See #postpone
	def postponed(context, generator, reason); super if defined? super end	

	# Call this method in the #calling hook to avoid calling the event
	# command. This raises an EventCanceled exception with +reason+ for message
	def cancel(reason = nil)
	    raise EventCanceled.new(self), (reason || "event canceled")
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

	# Hook called just after the event command has been called
	def called(context); super if defined? super end

	# Hook called when this generator has been fired. +event+ is the Event object
	# which has been created by this model
	def fired(event)
	    history << event
	    super if defined? super
	end

	# Hook called just before the +to+ generator is signalled by this
	# generator. +event+ is the Event object which has been generated by
	# this model
	def signalling(event, to); super if defined? super end
	
	# Hook called just before +from+ is forwarded by this generator.
	# +event+ is the Event object which has been generated by this model
	def forwarding(event, to); super if defined? super end

	def filter(new_context = nil, &block)
	    filter = FilterGenerator.new(new_context, &block)
	    self.on(filter)
	    filter
	end

	def until(limit); UntilGenerator.new(self, limit) end
    end

    # This generator reemits an event after having changed its context. See
    # EventGenerator#filter
    class FilterGenerator < EventGenerator
	def initialize(context = nil, &block)
	    if block && context
		raise ArgumentError, "you must set either the filter or the value, not both"
	    end

	    if block
		super() { |context| emit(block[context]) }
	    else
		super() { emit(context) }
	    end
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
	def removed_parent_object(parent, type)
	    super if defined? super
	    return unless type == EventStructure::Signal
	    @events.delete(parent)
	end

	def events;  enum_parent_objects(EventStructure::Signal).to_a end
	def waiting; enum_parent_objects(EventStructure::Signal).find_all { |ev| @events[ev] == ev.last } end
	
	def << (generator)
	    generator.add_signal self
	    self
	end
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
    end

    class UntilGenerator < Roby::EventGenerator
	def initialize(source = nil, limit = nil)
	    super() do |context|
		plan.remove_object(self) if plan 
		clear_relations
	    end

	    if source && limit
		source.forward(self)
		limit.signal(self)
	    end
	end
    end

    EventStructure = RelationSpace(EventGenerator)
end

