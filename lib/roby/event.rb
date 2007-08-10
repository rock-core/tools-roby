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

    class UnreachableEvent < EventModelViolation; end
    class EventNotExecutable < EventModelViolation; end
    class EventCanceled < EventModelViolation; end
    class EventPreconditionFailed < EventModelViolation; end

    class Event
	attr_reader :generator

	def initialize(generator, propagation_id, context, time = Time.now)
	    @generator, @propagation_id, @context, @time = generator, propagation_id, context.freeze, time
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
	def initialize(command_object = nil, &command_block)
	    @preconditions = []
	    @handlers = []
	    @pending  = false
	    @executable = true
	    @unreachable_handlers = []

	    super() if defined? super

	    if command_object || command_block
		self.command = if command_object.respond_to?(:call)
				   command_object
			       elsif command_block
				   command_block
			       else
				   method(:default_command)
			       end
	    end
	end

	def default_command(context)
	    emit(*context)
	end

	# The current command block
	attr_reader :command

	# Sets a command proc for this event generator. Sets controlable to true
	attr_writer :command
	
	# True if this event is controlable
	def controlable?; !!@command end

	# Returns true if the command has been called and false otherwise
	# The command won't be called if #postpone() is called within the
	# #calling hook
	#
	# This is used by propagation code, and should never be called directly
	def call_without_propagation(context) # :nodoc:
	    if !controlable?
		raise EventModelViolation.new(self), "#call called on a non-controlable event"
	    end

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
	def call(*context)
	    if !self_owned?
		raise OwnershipError, "not owner"
	    elsif !controlable?
		raise EventModelViolation.new(self), "#call called on a non-controlable event"
	    elsif !executable?
		raise EventNotExecutable.new(self), "#call called on #{self} which is non-executable event"
	    elsif !Roby.inside_control?
		raise EventNotExecutable.new(self), "#call called while not in control thread"
	    end

	    context.compact!
	    if Propagation.gathering?
		Propagation.add_event_propagation(false, Propagation.source_events, self, (context unless context.empty?), nil)
	    else
		errors = Propagation.propagate_events do |initial_set|
		    initial_set << self if call_without_propagation((context unless context.empty?))
		end
		errors.each { |e| raise e.exception }
	    end
	end

	# Establishes signalling and/or event handlers from this event
	# generator.  If +time+ is non-nil, it is a delay (in seconds) which
	# must pass between the time this event is emitted and the time
	# +signal+ is called
	def on(signal = nil, time = nil, &handler)
	    if signal
		self.signal(signal, time)
	    end

	    if handler
		check_arity(handler, 1)
		self.handlers << handler
	    end

	    self
	end

	# Adds a signal from this event to +generator+. +generator+ must be
	# controlable.  If +timespec+ is given, it is a delay, in seconds,
	# between the instant this event is fired and the instant +generator+
	# must be called.
	def signal(generator, timespec = nil)
	    if !generator.controlable?
		raise EventModelViolation.new(self), "trying to establish a signal between #{self} and #{generator}"
	    end
	    timespec = Propagation.validate_timespec(timespec)

	    add_signal generator, timespec
	    self
	end

	# A set of blocks called when this event cannot be emitted again
	attr_reader :unreachable_handlers

	# Calls +block+ if it is impossible that this event is ever emitted
	def if_unreachable(cancel_at_emission = false, &block)
	    unreachable_handlers << [cancel_at_emission, block]
	    block.object_id
	end

	# Emit +generator+ when +self+ is fired, without calling the command of
	# +generator+, if any. If +timespec+ is given it is a delay in seconds
	# between the instant this event is fired and the instant +generator+
	# is fired
	def forward(generator, timespec = nil)
	    timespec = Propagation.validate_timespec(timespec)
	    add_forwarding generator, timespec
	    self
	end

	# Returns an event which is emitted +seconds+ seconds after this one
	def delay(seconds)
	    if seconds == 0 then self
	    else
		ev = EventGenerator.new
		forward(ev, :delay => seconds)
		ev
	    end
	end

	# Signal the +signal+ event the first time this event is emitted.  If
	# +time+ is non-nil, delay the signalling this many seconds. 
	def signal_once(signal, time = nil)
	    on(signal, time) { remove_signal(signal) }
	end

	def to_event; self end

	# Returns the set of events directly related to this one
	def related_events(result = nil); related_objects(nil, result) end
	# Returns the set of tasks directly related to this event
	def related_tasks(result = nil)
	    result ||= ValueSet.new
	    for ev in related_events
		if ev.respond_to?(:task)
		    result << ev.task
		end
	    end
	    result
	end

	# Create a new event object for +context+
	def new(context); Event.new(self, Propagation.propagation_id, context, Time.now) end

	# Adds a propagation originating from this event to event propagation
	def add_propagation(only_forward, event, signalled, context, timespec) # :nodoc:
	    if self == signalled
		raise EventModelViolation.new(self), "#{self} is trying to signal itself"
	    elsif !only_forward && !signalled.controlable?
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
		    add_propagation(false, event, signalled, event.context, self[signalled, EventStructure::Signal])
		end
		each_forwarding do |signalled|
		    add_propagation(true, event, signalled, event.context, self[signalled, EventStructure::Forwarding])
		end

		@happened = true
		fired(event)

		call_handlers(event)
	    end
	end

	private :fire
	
	# Call the event handlers defined for this event generator
	def call_handlers(event)
	    # Since we are in a gathering context, call
	    # to other objects are not done, but gathered in the 
	    # :propagation TLS
	    each_handler do |h| 
		Propagation.gather_exceptions(self) { h.call(event) }
	    end
	end

	# Raises an exception object when an event whose command has been
	# called won't be emitted (ever)
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

	# Emits the event regardless of wether we are in a propagation context
	# or not Returns true to match the behavior of
	# #call_without_propagation
	#
	# This is used by event propagation. Do not call directly: use #call instead
	def emit_without_propagation(context) # :nodoc:
	    if !executable?
		raise EventNotExecutable.new(self), "#emit called on #{self} which is not executable"
	    end

	    emitting(context)

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

	# Emit the event with +context+ as the event context
	def emit(*context)
	    if !executable?
		raise EventNotExecutable.new(self), "#emit called on #{self} which is not executable"
	    elsif !self_owned?
		raise OwnershipError, "cannot emit an event we don't own. #{self} is owned by #{owners}"
	    elsif !Roby.inside_control?
		raise EventNotExecutable.new(self), "#emit called while not in control thread"
	    end

	    context.compact!
	    if Propagation.gathering?
		Propagation.add_event_propagation(true, Propagation.source_events, self, (context unless context.empty?), nil)
	    else
		errors = Propagation.propagate_events do |initial_set|
		    initial_set << self
		    emit_without_propagation((context unless context.empty?))
		end
		errors.each { |e| raise e.exception }
	    end
	end

	# Deprecated. Instead of using
	#   dest.emit_on(source)
	# now use
	#   source.forward(dest)
	def emit_on(generator, timespec = nil)
	    generator.forward(self, timespec)
	    self
	end

	# Sets up +obj+ and +self+ so that obj+ is used
	# to execute the command of +self+. It is to be used in
	# a command handler:
	#   event :start do |context|
	#	init = <create an initialization task>
	#	event(:start).realize_with(task)
	#   end
	#
	# or 
	#   event :start do |context|
	#	init = <create an initialization task>
	#	event(:start).realize_with(task)
	#   end
	def achieve_with(obj)
	    stack = caller(1)
	    if block_given?
		obj.add_causal_link self
		obj.on do |context|
		    self.emit(*yield(context))
		end
	    else
		obj.forward self
	    end

	    obj.if_unreachable(true) do
		msg = "#{obj} is unreachable, in #{stack.first}"
		if obj.respond_to?(:task)
		    msg << "\n  " << obj.task.history.map { |ev| "#{ev.time.to_hms} #{ev.symbol}: #{ev.context}" }.join("\n  ")
		end
		emit_failed(EventModelViolation.new(self), msg)
	    end
	end
	# For backwards compatibility. Use #achieve_with.
	def realize_with(task); achieve_with(task) end

	# A [time, event] array of past event emitted by this object
	attribute(:history) { Array.new }
	# True if this event has been emitted once.
	attr_predicate :happened
	# Last event to have been emitted by this generator
	def last; history.last end

	# Defines a precondition handler for this event. Precondition handlers
	# are checked before calling the command. If the handler returns false,
	# the calling is aborted by a PreconditionFailed exception
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

	# Call this method in the #calling hook to cancel calling the event
	# command. This raises an EventCanceled exception with +reason+ for
	# message
	def cancel(reason = nil)
	    raise EventCanceled.new(self), (reason || "event canceled")
	end

	# Hook called when this event generator is called (i.e. the associated
	# command is), before the command is actually called. Think of it as a
	# pre-call hook.
	#
	# The #postpone method can be called in this hook
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
	# which has been created.
	def fired(event)
	    unreachable_handlers.delete_if { |cancel, _| cancel }

	    history << event
	    collection, _ = EventGenerator.event_gathering.find do |c, events| 
		events.any? { |ev| ev == event.generator }
	    end
	    if collection
		collection << event
	    end

	    super if defined? super
	end

	# Hook called just before the +to+ generator is signalled by this
	# generator. +event+ is the Event object which has been generated by
	# this model
	def signalling(event, to); super if defined? super end
	
	# Hook called just before the propagation forwards +self+ to +to+.
	# +event+ is the Event object which has been generated by this model
	def forwarding(event, to); super if defined? super end
	
	# Hook called when this event will be emitted
	def emitting(context); super if defined? super end

	# call-seq:
	#   filter(new_context) => filtering_event
	#   filter { |context| ... } => filtering_event
	#
	# Returns an event generator which forwards the events fired by this
	# one, but by changing the context. In the first form, the new context
	# is set to +new_context+.  In the second form, to the value returned
	# by the given block
	def filter(*new_context, &block)
	    filter = FilterGenerator.new(new_context, &block)
	    self.on(filter)
	    filter
	end

	# Returns a new event generator which emits until the +limit+ event is
	# sent
	#
	#   source, ev, limit = (1..3).map { EventGenerator.new(true) }
	#   ev.until(limit).on { STDERR.puts "FIRED !!!" }
	#   source.on ev
	#
	# Will do
	#
	#   source.call # => FIRED !!!
	#   limit.emit
	#   source.call # => 
	#
	# See also UntilGenerator
	def until(limit); UntilGenerator.new(self, limit) end
	
	# Checks that ownership allows to add the self => child relation
	def add_child_object(child, type, info) # :nodoc:
	    unless child.read_write?
		raise NotOwner, "cannot add an event relation on a child we don't own. #{child} is owned by #{child.owners.to_a} (#{plan.owners.to_a if plan})"
	    end

	    super
	end

	@@event_gathering = Array.new
	# If a generator in +events+ fires, add the fired event in +collection+
	def self.gather_events(collection, *events)
	    gathered_events = events_gathered_into(collection)
	    if gathered_events
		gathered_events.merge events.to_value_set
	    else
		event_gathering << [collection, events.to_value_set]
	    end
	end
	# Remove the notifications that have been registered for +collection+
	def self.remove_event_gathering(collection)
	    @@event_gathering.delete_if { |c, _| c.object_id == collection.object_id }
	end
	# An array of [collection, events] elements, collection being the
	# object in which we must add the fired events, and events the set of
	# event generators +collection+ is listening for.
	def self.event_gathering; @@event_gathering end
	def self.events_gathered_into(collection)
	    _, events = event_gathering.find { |c, _| c.object_id == collection.object_id }
	    events
	end

	# This module is hooked in Roby::Plan to remove from the
	# event_gathering sets the events that have been finalized
	module FinalizedEventHook
	    def finalized_event(event)
		super if defined? super

		event.unreachable!
		EventGenerator.event_gathering.each do |collection, events|
		    events.delete(event)
		end
	    end
	end
	Roby::Plan.include FinalizedEventHook

	attr_predicate :unreachable?

	# Called internally when the event becomes unreachable
	def unreachable!
	    @unreachable = true

	    unreachable_handlers.each do |_, block|
		Propagation.gather_exceptions(self) do
		    block.call(self)
		end
	    end
	    unreachable_handlers.clear
	end

	def pretty_print(pp) # :nodoc:
	    pp.text to_s
	    pp.group(2, ' {', '}') do
		pp.breakable
		pp.text "owners: "
		pp.seplist(owners) { |r| pp.text r.to_s }

		pp.breakable
		pp.text "relations: "
		pp.seplist(relations) { |r| pp.text r.name }
	    end
	end
    end


    # This generator reemits an event after having changed its context. See
    # EventGenerator#filter for a more complete explanation
    class FilterGenerator < EventGenerator
	def initialize(user_context, &block)
	    if block && !user_context.empty?
		raise ArgumentError, "you must set either the filter or the value, not both"
	    end

	    if block
		super() do |context| 
		    context = context.map do |val|
			block.call(val)
		    end
		    emit(*context)
		end
	    else
		super() do 
		    emit(*user_context)
		end
	    end
	end
    end

    # Event generator which fires when all its source events have fired
    # See EventGenerator#& for a more complete description
    class AndGenerator < EventGenerator
	def initialize
	    super do |context|
		emit_if_achieved(context)
	    end

	    # This hash is a event_generator => event mapping of the last
	    # events of each event generator. We compare the event stored in
	    # this hash with the last events of each source to know if the
	    # source fired since it has been added to this AndGenerator
	    @events = Hash.new
	end

	def emit_if_achieved(context) # :nodoc:
	    return if happened?
	    each_parent_object(EventStructure::Signal) do |source|
		return if @events[source] == source.last
	    end
	    emit(nil)
	end

	def empty?; events.empty? end
	
	# Adds a new source to +events+ when a source event is added
	def added_parent_object(parent, type, info) # :nodoc:
	    super if defined? super
	    return unless type == EventStructure::Signal
	    @events[parent] = parent.last

	    parent.if_unreachable(true) do
		# Check that the parent has not been removed since ...
		if @events.has_key?(parent)
		    unreachable!
		end
	    end
	end
	# Removes a source from +events+ when the source is removed
	def removed_parent_object(parent, type) # :nodoc:
	    super if defined? super
	    return unless type == EventStructure::Signal
	    @events.delete(parent)
	end

	# The set of source events
	def events;  parent_objects(EventStructure::Signal) end
	# The set of events which we are waiting for
	def waiting; parent_objects(EventStructure::Signal).find_all { |ev| @events[ev] == ev.last } end
	
	# Add a new source to this generator
	def << (generator)
	    generator.add_signal self
	    self
	end
    end

    # Event generator which fires when the first of its source events fires
    # See EventGenerator#| for a more complete description
    class OrGenerator < EventGenerator
	def initialize
	    super do |context|
		emit_if_first(context)
	    end
	end

	def empty?; parent_objects(EventStructure::Signal).empty? end

	def emit_if_first(context) # :nodoc:
	    return if happened?
	    emit(context)
	end
	
	def added_parent_object(parent, type, info) # :nodoc:
	    super if defined? super
	    return unless type == EventStructure::Signal

	    parent.if_unreachable do
		if parent_objects(EventStructure::Signal).all? { |ev| ev.unreachable? }
		    unreachable!
		end
	    end
	end

	# Adds +generator+ to the sources of this event
	def << (generator)
	    generator.add_signal self
	    self
	end
    end

    # Event generator which fires only until a certain other event is reached.
    # See EventGenerator#until for a more complete description
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

    unless defined? EventStructure
	EventStructure = RelationSpace(EventGenerator)
    end
end

