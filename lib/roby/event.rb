module Roby
    # Event objects are the objects representing a particular emission in the
    # event propagation process. They represent the common propagation
    # information (time, generator, sources, ...) and provide some common
    # functionalities related to propagation as well.
    class Event
        # The generator which emitted this event
	attr_reader :generator

        @@creation_places = Hash.new
	def initialize(generator, propagation_id, context, time = Time.now)
	    @generator, @propagation_id, @context, @time = generator, propagation_id, context.freeze, time

            @@creation_places[object_id] = "#{generator.class}"
	end

	attr_accessor :propagation_id, :context, :time
	protected :propagation_id=, :context=, :time=

        # The events whose emission triggered this event during the
        # propagation. The events in this set are subject to Ruby's own
        # garbage collection, which means that if a source event is garbage
        # collected (i.e. if all references to the associated task/event
        # generator are removed), it will be removed from this set as well.
        def sources
            result = []
            @sources.delete_if do |ref|
                begin 
                    result << ref.get
                    false
                rescue Utilrb::WeakRef::RefError
                    true
                end
            end
            result
        end

        # Sets the sources. See #sources
        def sources=(sources) # :nodoc:
            @sources = ValueSet.new
            for s in sources
                @sources << Utilrb::WeakRef.new(s)
            end
        end

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
	def inspect # :nodoc:
            "#<#{model.to_s}:0x#{address.to_s(16)} generator=#{generator} model=#{model}"
        end

        # Returns an event generator which will be emitted once +time+ seconds
        # after this event has been emitted.
        def after(time)
            State.at :t => (self.time + time)
        end

	def to_s # :nodoc:
	    "[#{time.to_hms} @#{propagation_id}] #{self.class.to_s}: #{context}"
	end

        def pretty_print(pp) # :nodoc:
            pp.text "[#{time.to_hms} @#{propagation_id}] #{self.class}"
            if context
                pp.breakable
                pp.nest(2) do
                    pp.text "  "
                    pp.seplist(context) { |v| v.pretty_print(pp) }
                end
            end
        end
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

	def initialize_copy(old) # :nodoc:
	    super

	    @history = old.history.dup
	end

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
	    @unreachable = false
	    @unreachable_handlers = []

	    if command_object || command_block
		self.command = if command_object.respond_to?(:call)
				   command_object
			       elsif command_block
				   command_block
			       else
				   method(:default_command)
			       end
	    end
	    super() if defined? super

	end

	def default_command(context)
	    emit(*context)
	end

	# The current command block
	attr_accessor :command

	# True if this event is controlable
	def controlable?; !!@command end

	# Checks that the event can be called. Raises various exception
	# when it is not the case.
	def check_call_validity
	    if !executable?
		raise EventNotExecutable.new(self), "#call called on #{self} which is a non-executable event"
	    elsif !self_owned?
		raise OwnershipError, "not owner"
	    elsif !controlable?
		raise EventNotControlable.new(self), "#call called on a non-controlable event"
	    elsif !engine.inside_control?
		raise ThreadMismatch, "#call called while not in control thread"
	    end
	end

	# Checks that the event can be emitted. Raises various exception
	# when it is not the case.
	def check_emission_validity
	    if !executable?
		raise EventNotExecutable.new(self), "#emit called on #{self} which is a non-executable event"
	    elsif !self_owned?
		raise OwnershipError, "cannot emit an event we don't own. #{self} is owned by #{owners}"
	    elsif !engine.inside_control?
		raise ThreadMismatch, "#emit called while not in control thread"
	    end
	end

	# Returns true if the command has been called and false otherwise
	# The command won't be called if #postpone() is called within the
	# #calling hook, in which case the method returns false.
	#
	# This is used by propagation code, and should never be called directly
	def call_without_propagation(context)
            check_call_validity
            
	    if !controlable?
		raise EventNotControlable.new(self), "#call called on a non-controlable event"
	    end

	    postponed = catch :postponed do 
		calling(context)
		@pending = true

		plan.engine.propagation_context([self]) do
		    command[context]
		end

		false
	    end

	    if postponed
		@pending = false
		postponed(context, *postponed)
		false
	    else
		called(context)
		true
	    end

	rescue Exception
	    @pending = false
	    raise
	end

	# Call the command associated with self. Note that an event might be
	# non-controlable and respond to the :call message. Controlability must
	# be checked using #controlable?
	def call(*context)
            check_call_validity

	    context.compact!
            engine = plan.engine
	    if engine.gathering?
		engine.add_event_propagation(false, engine.propagation_sources, self, (context unless context.empty?), nil)
	    else
		Roby.synchronize do
		    errors = engine.propagate_events do |initial_set|
			engine.add_event_propagation(false, nil, self, (context unless context.empty?), nil)
		    end
		    if errors.size == 1
			e = errors.first.exception
			raise e, e.message, e.backtrace
		    elsif !errors.empty?
			for e in errors
			    STDERR.puts e.exception.full_message
			end
			raise "multiple exceptions"
		    end
		end
	    end
	end

	# Establishes signalling and/or event handlers from this event
	# generator. 
        #
        # If +time+ is given it is either a :delay => time association, or a
        # :at => time association. In the first case, +time+ is a floating-point
        # delay in seconds and in the second case it is a Time object which is
        # the absolute point in time at which this propagation must happen.
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
        def signals(generator, timespec = nil)
            signal(generator, timespec)
        end

	# Adds a signal from this event to +generator+. +generator+ must be
	# controlable.
        #
        # If +time+ is given it is either a :delay => time association, or a
        # :at => time association. In the first case, +time+ is a floating-point
        # delay in seconds and in the second case it is a Time object which is
        # the absolute point in time at which this propagation must happen.
	def signal(generator, timespec = nil)
	    if !generator.controlable?
		raise EventNotControlable.new(self), "trying to establish a signal from #{self} to #{generator} which is not controllable"
	    end
	    timespec = ExecutionEngine.validate_timespec(timespec)

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

        # Returns an event which will be emitted when this event becones
        # unreachable
        def when_unreachable
            # NOTE: the unreachable event is not directly tied to this one from
            # a GC point of view (being able to do this would be useful, but
            # anyway). So, it is possible that it is GCed because the event
            # user did not take care to use it.
            if !@unreachable_event || !@unreachable_event.plan
                result = EventGenerator.new(true)
                if_unreachable(false) do
                    if result.plan
                        result.emit
                    end
                end
                add_causal_link result
                @unreachable_event = result
            end
            @unreachable_event
        end

        # Emit +generator+ when +self+ is fired, without calling the command of
        # +generator+, if any.
        #
        # If +timespec+ is given it is either a :delay => time association, or a
        # :at => time association. In the first case, +time+ is a floating-point
        # delay in seconds and in the second case it is a Time object which is
        # the absolute point in time at which this propagation must happen.
	def forward(generator, timespec = nil)
	    timespec = ExecutionEngine.validate_timespec(timespec)
	    add_forwarding generator, timespec
	    self
	end

        def forward_to(generator, timespec = nil)
            forward(generator, timespec)
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
	def signal_once(signal, time = nil); once(signal, time) end

	# Equivalent to #on, but call the handler and/or signal the target
	# event only once.
	def once(signal = nil, time = nil)
	    handler = nil
	    on(signal, time) do |context|
		yield(context) if block_given?
		self.handlers.delete(handler)
		remove_signal(signal) if signal
	    end
	    handler = self.handlers.last
	end

	# Forwards to +ev+ only once
	def forward_once(ev)
	    forward(ev)
	    once do
		remove_forwarding ev
	    end
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
	def new(context); Event.new(self, plan.engine.propagation_id, context, Time.now) end

	# Adds a propagation originating from this event to event propagation
	def add_propagation(only_forward, event, signalled, context, timespec) # :nodoc:
	    if self == signalled
		raise PropagationError, "#{self} is trying to signal itself"
	    elsif !only_forward && !signalled.controlable?
		raise PropagationError, "trying to signal #{signalled} from #{self}"
	    end

	    plan.engine.add_event_propagation(only_forward, [event], signalled, context, timespec)
	end
	private :add_propagation

	# Do fire this event. It gathers the list of signals that are to
	# be propagated in the next step and calls fired()
	#
	# This method is always called in a propagation context
	def fire(event)
	    plan.engine.propagation_context([event]) do |result|
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
		begin
		    h.call(event)
		rescue Exception => e
		    plan.engine.add_error( EventHandlerError.new(e, event) )
		end
	    end
	end

	# Raises an exception object when an event whose command has been
	# called won't be emitted (ever)
	def emit_failed(*what)
	    what, message = *what
	    what ||= EmissionFailed

	    if !message && what.respond_to?(:to_str)
		message = what.to_str
		what = EmissionFailed
	    end

	    failure_message = "failed to emit #{self}: #{message}"
	    error = if Class === what then what.new(nil, self)
		    else what
		    end
	    error = error.exception failure_message

	    plan.engine.add_error(error)

	ensure
	    @pending = false
	end

	# Emits the event regardless of wether we are in a propagation context
	# or not. Returns true to match the behavior of #call_without_propagation
	#
	# This is used by event propagation. Do not call directly: use #call instead
	def emit_without_propagation(context)
            check_emission_validity
            
	    if !executable?
		raise EventNotExecutable.new(self), "#emit called on #{self} which is not executable"
	    end

	    emitting(context)

	    # Create the event object
	    event = new(context)
	    unless event.respond_to?(:context)
		raise TypeError, "#{event} is not a valid event object in #{self}"
	    end
	    event.sources = plan.engine.propagation_source_events
	    fire(event)

	    true

	ensure
	    @pending = false
	end

	# Emit the event with +context+ as the event context
	def emit(*context)
            check_emission_validity

	    context.compact!
            engine = plan.engine
	    if engine.gathering?
		engine.add_event_propagation(true, engine.propagation_sources, self, (context unless context.empty?), nil)
	    else
		Roby.synchronize do
		    errors = engine.propagate_events do |initial_set|
			engine.add_event_propagation(true, engine.propagation_sources, self, (context unless context.empty?), nil)
		    end
		    if errors.size == 1
			e = errors.first.exception
			raise e, e.message, e.backtrace
		    elsif !errors.empty?
			for e in errors
			    STDERR.puts e.full_message
			end
			raise "multiple exceptions"
		    end
		end
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

        # Sets up +ev+ and +self+ to represent that the command of +self+ is to
        # be achieved by the emission of +ev+. It is to be used in a command
        # handler:
        #
	#   event :start do |context|
	#	init = <create an initialization event>
	#	event(:start).achieve_with(init)
	#   end
        #
        # If +ev+ becomes unreachable, an EmissionFailed exception will be
        # raised. If a block is given, it is supposed to return the context of
        # the event emitted by +self+, given the context of the event emitted
        # by +ev+.
        #
        # From an event propagation point of view, it looks like:
        # TODO: add a figure
	def achieve_with(ev)
	    stack = caller(1)
	    if block_given?
		ev.add_causal_link self
		ev.once do |context|
		    self.emit(yield(context))
		end
	    else
		ev.forward_once self
	    end

	    ev.if_unreachable(true) do |reason|
		msg = "#{ev} is unreachable#{ " (#{reason})" if reason }, in #{stack.first}"
		if ev.respond_to?(:task)
		    msg << "\n  " << ev.task.history.map { |ev| "#{ev.time.to_hms} #{ev.symbol}: #{ev.context}" }.join("\n  ")
		end
		emit_failed(UnreachableEvent.new(self, reason), msg)
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
        # are blocks which are called just before the event command is called.
        # If the handler returns false, the calling is aborted by a
        # PreconditionFailed exception
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
	    if EventGenerator.event_gathering.has_key?(event.generator)
		for c in EventGenerator.event_gathering[event.generator]
		    c << event
		end
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
		raise OwnershipError, "cannot add an event relation on a child we don't own. #{child} is owned by #{child.owners.to_a} (plan is owned by #{plan.owners.to_a if plan})"
	    end

	    super
	end

        def added_child_object(child, relations, info) # :nodoc:
            super if defined? super
            if relations.include?(Roby::EventStructure::Precedence) && plan && plan.engine
                plan.engine.event_ordering.clear
            end
        end
        def removed_child_object(child, relations) # :nodoc:
            super if defined? super
            if relations.include?(Roby::EventStructure::Precedence) && plan && plan.engine
                plan.engine.event_ordering.clear
            end
        end

	@@event_gathering = Hash.new { |h, k| h[k] = ValueSet.new }
	# If a generator in +events+ fires, add the fired event in +collection+
	def self.gather_events(collection, events)
	    for ev in events
		event_gathering[ev] << collection
	    end
	end
	# Remove the notifications that have been registered for +collection+
	def self.remove_event_gathering(collection)
	    @@event_gathering.delete_if do |_, collections| 
		collections.delete(collection)
		collections.empty?
	    end
	end
	# An array of [collection, events] elements, collection being the
	# object in which we must add the fired events, and events the set of
	# event generators +collection+ is listening for.
	def self.event_gathering; @@event_gathering end

	attr_predicate :unreachable?

	# Called internally when the event becomes unreachable
	def unreachable!(reason = nil, plan = self.plan)
	    return if @unreachable
	    @unreachable = true

            EventGenerator.event_gathering.delete(self)

	    unreachable_handlers.each do |_, block|
		begin
		    block.call(reason)
		rescue Exception => e
		    plan.engine.add_error(EventHandlerError.new(e, self))
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

	    # This flag is true unless we are not waiting for the emission
	    # anymore.
	    @active = true
	end

	# Resets the waiting. If the event has already been emitted, it re-arms
	# it.
	def reset
	    @active = true
	    each_parent_object(EventStructure::Signal) do |source|
		@events[source] = source.last
		if source.respond_to?(:reset)
		    source.reset
		end
	    end
	end

	def emit_if_achieved(context) # :nodoc:
	    return unless @active
	    each_parent_object(EventStructure::Signal) do |source|
		return if @events[source] == source.last
	    end
	    @active = false
	    emit(nil)
	end

	def empty?; events.empty? end
	
	# Adds a new source to +events+ when a source event is added
	def added_parent_object(parent, relations, info) # :nodoc:
	    super if defined? super
	    return unless relations.include?(EventStructure::Signal)
	    @events[parent] = parent.last

	    # If the parent is unreachable, check that it has neither been
	    # removed, nor it has been emitted
	    parent.if_unreachable(true) do |reason|
		if @events[parent] == parent.last
		    unreachable!(reason || parent)
		end
	    end
	end

	# Removes a source from +events+ when the source is removed
	def removed_parent_object(parent, relations) # :nodoc:
	    super if defined? super
	    return unless relations.include?(EventStructure::Signal)
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

    # Event generator which fires when the first of its source events fires.
    # All event generators which signal this one are considered as sources.
    #
    # See also EventGenerator#| and #<<
    class OrGenerator < EventGenerator
        # Creates a new OrGenerator without any sources.
	def initialize
	    super do |context|
		emit_if_first(context)
	    end
	    @active = true
	end

        # True if there is no source event for this combinator.
	def empty?; parent_objects(EventStructure::Signal).empty? end

        # Reset its state, so as to behave as if no source has ever
        # been emitted.
	def reset
	    @active = true
	    each_parent_object(EventStructure::Signal) do |source|
		if source.respond_to?(:reset)
		    source.reset
		end
	    end
	end

	def emit_if_first(context) # :nodoc:
	    return unless @active
	    @active = false
	    emit(context)
	end

	def added_parent_object(parent, relations, info) # :nodoc:
	    super if defined? super
	    return unless relations.include?(EventStructure::Signal)

	    parent.if_unreachable(true) do |reason|
		if !happened? && parent_objects(EventStructure::Signal).all? { |ev| ev.unreachable? }
		    unreachable!(reason || parent)
		end
	    end
	end

	# Adds +generator+ to the sources of this event
	def << (generator)
	    generator.add_signal self
	    self
	end
    end

    # This event generator combines a source and a limit in a temporal pattern.
    # The generator acts as a pass-through for the source, until the limit is
    # itself emitted. It means that:
    #
    # * before the limit is emitted, the generator will emit each time its
    #  source emits 
    # * since the point where the limit is emitted, the generator
    #   does not emit anymore
    #
    # See also EventGenerator#until
    class UntilGenerator < Roby::EventGenerator
        # Creates a until generator for the given source and limit event
        # generators
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

