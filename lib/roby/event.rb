module Roby
    # Event objects are the objects representing a particular emission in the
    # event propagation process. They represent the common propagation
    # information (time, generator, sources, ...) and provide some common
    # functionalities related to propagation as well.
    class Event
        # The generator which emitted this event
	attr_reader :generator

	def initialize(generator, propagation_id, context, time = Time.now)
	    @generator, @propagation_id, @context, @time = generator, propagation_id, context.freeze, time
            @sources = ValueSet.new
	end

	attr_accessor :propagation_id, :context, :time
	protected :propagation_id=, :context=, :time=

        # The events whose emission directly triggered this event during the
        # propagation. The events in this set are subject to Ruby's own
        # garbage collection, which means that if a source event is garbage
        # collected (i.e. if all references to the associated task/event
        # generator are removed), it will be removed from this set as well.
        def sources
            result = ValueSet.new
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

        # Recursively computes the source event that led to the emission of
        # +self+
        def all_sources
            result = ValueSet.new
            sources.each do |ev|
                result << ev
                result.merge(ev.all_sources)
            end
            result
        end

        # Call to protect this event's source from Ruby's garbage collection.
        # Call this if you want to store the propagation history for this event
        def protect_sources
            @protected_sources = sources
        end

        # Call to recursively protect this event's sources from Ruby's garbage
        # collection. Call this if you want to store the propagation history for
        # this event
        def protect_all_sources
            @protected_all_sources = all_sources
        end

        # Sets the sources. See #sources
        def sources=(new_sources) # :nodoc:
            @sources = ValueSet.new
            add_sources(new_sources)
        end

        def add_sources(new_sources)
            for new_s in new_sources
                @sources << Utilrb::WeakRef.new(new_s)
            end
        end

        def root_sources
            all = all_sources
            all.find_all do |event|
                all.none? { |ev| ev.generator.child_object?(event.generator, Roby::EventStructure::Forwarding) }
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
	    "[#{Roby.format_time(time)} @#{propagation_id}] #{self.class.to_s}: #{context}"
	end

        def pretty_print(pp) # :nodoc:
            pp.text "[#{Roby.format_time(time)} @#{propagation_id}] #{self.class}"
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
        # The event class that is used to represent this generator's emissions
        #
        # Defaults to Event
        attr_reader :event_model

	# Creates a new Event generator which is emitted as soon as one of this
	# object and +generator+ is emitted
        #
        # See OrGenerator for a complete description.
        #
        # Note that this operator always creates a new generator, thus
        #
        #  a | b | c | d
        #
        # will create 3 OrGenerator instances. It is in general better to use |
        # for event pairs, and use OrGenerator#<< when multiple events have to be
        # aggregated:
        #
        #  OrGenerator.new << a << b << c << d
        #
	def |(generator)
	    OrGenerator.new << self << generator
	end

	# Creates a AndGenerator object which is emitted when both this object
	# and +generator+ are emitted
        #
        # See AndGenerator for a complete description.
        #
        # Note that this operator always creates a new generator, thus
        #
        #  a & b & c & d
        #
        # will create 3 AndGenerator instances. It is in general better to use &
        # for event pairs, and use AndGenerator#<< when multiple events have to
        # be aggregated:
        #
        #  AndGenerator.new << a << b << c << d
        #
	def &(generator)
	    AndGenerator.new << self << generator
	end

	attr_enumerable(:handler, :handlers) { Array.new }

	def initialize_copy(old) # :nodoc:
	    super

            @event_model = old.event_model
            @preconditions = old.instance_variable_get(:@preconditions).dup
            @handlers = old.handlers.dup
            @happened = old.happened?
	    @history  = old.history.dup
            @pending  = false
            if old.command.kind_of?(Method)
                @command = method(old.command.name)
            end
            @unreachable = old.unreachable?
            @unreachable_handlers = old.unreachable_handlers.dup
	end

        # Returns the model object for this particular event generator. It is in
        # general the generator class.
	def model; self.class end
	# The model name
	def name; model.name end
	# The count of command calls that have not a corresponding emission
	attr_reader :pending
	# True if this event has been called but is not emitted yet
	def pending?; pending || (engine && engine.has_propagation_for?(self)) end

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
	    @handlers      = []
	    @pending       = false
	    @unreachable   = false
            @unreachable_events   = Hash.new
	    @unreachable_handlers = []
	    @history       = Array.new
            @event_model = Event

	    if command_object || command_block
		@command = if command_object.respond_to?(:call)
				   command_object
			       elsif command_block
				   command_block
			       else
				   method(:default_command)
			       end
            else
                @command = nil
	    end
	    super() if defined? super
	end

        # The default command of emitted the event
	def default_command(context) # :nodoc:
	    emit(*context)
	end

	# The current command block
	attr_accessor :command

	# True if this event is controlable
	def controlable?; !!@command end

	# Checks that the event can be called. Raises various exception
	# when it is not the case.
	def check_call_validity
            if !plan
		raise EventNotExecutable.new(self), "#emit called on #{self} which is in no plan"
            elsif !engine
		raise EventNotExecutable.new(self), "#emit called on #{self} which is has no associated execution engine"
            elsif !engine.allow_propagation?
                raise PhaseMismatch, "call to #emit is not allowed in this context"
	    elsif !controlable?
		raise EventNotControlable.new(self), "#call called on a non-controlable event"
            elsif unreachable?
                if unreachability_reason
                    raise UnreachableEvent.new(self, unreachability_reason), "#call called on #{self} which has been made unreachable because of #{unreachability_reason}"
                else
                    raise UnreachableEvent.new(self, unreachability_reason), "#call called on #{self} which has been made unreachable"
                end
	    elsif !engine.inside_control?
		raise ThreadMismatch, "#call called while not in control thread"
	    end
	end

	# Checks that the event can be emitted. Raises various exception
	# when it is not the case.
	def check_emission_validity
	    if !executable?
		raise EventNotExecutable.new(self), "#emit called on #{self} which is a non-executable event"
            elsif unreachable?
                if unreachability_reason
                    raise UnreachableEvent.new(self, unreachability_reason), "#emit called on #{self} which has been made unreachable because of #{unreachability_reason}"
                else
                    raise UnreachableEvent.new(self, unreachability_reason), "#emit called on #{self} which has been made unreachable"
                end
            elsif !engine.allow_propagation?
                raise PhaseMismatch, "call to #emit is not allowed in this context"
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
                if !executable?
                    raise EventNotExecutable.new(self), "#call called on #{self} which is a non-executable event"
                end

		@pending = true
                @pending_sources = plan.engine.propagation_source_events
		plan.engine.propagation_context([self]) do
                    begin
                        @calling_command = true
                        @command_emitted = false
                        command[context]
                    ensure
                        @calling_command = false
                    end
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
	end

        # Right after a call to #call_without_propagation, tells the caller
        # whether the command has emitted or not. This can be used to determine
        # in which context errors should be raised
        attr_predicate :command_emitted?, false
        
	# Call the command associated with self. Note that an event might be
	# non-controlable and respond to the :call message. Controlability must
	# be checked using #controlable?
	def call(*context)
            check_call_validity

            # This test must not be done in #emit_without_propagation as the
            # other ones: it is possible, using Distributed.update, to disable
            # ownership tests, but that does not work if the test is in
            # #emit_without_propagation
	    if !self_owned?
		raise OwnershipError, "not owner"
            end

	    context.compact!
            engine = plan.engine
	    if engine.gathering?
		engine.add_event_propagation(false, engine.propagation_sources, self, (context unless context.empty?), nil)
            else
		Roby.synchronize do
                    seeds = engine.gather_propagation do
			engine.add_event_propagation(false, engine.propagation_sources, self, (context unless context.empty?), nil)
                    end
		    engine.process_events_synchronous(seeds)
                    if unreachable? && unreachability_reason.kind_of?(Exception)
                        raise unreachability_reason
                    end
		end
	    end
	end

        # Class used to register event handler blocks along with their options
        class EventHandler
            attr_reader :block
            
            def initialize(block, copy_on_replace, once)
                @block, @copy_on_replace, @once = block, copy_on_replace, once
            end

            # True if this event handler should be moved to the new task in case
            # of replacements
            #
            # The default in Task#on is false for non-abstract tasks and true
            # for abstract tasks.
            def copy_on_replace?; !!@copy_on_replace end

            # True if this event handler should be called only once
            def once?; !!@once end

            # Generates an option hash valid for EventGenerator#on
            def as_options
                mode = if copy_on_replace? then :copy
                       else :drop
                       end

                { :on_replace => mode, :once => once? }
            end

            def ==(other)
                @copy_on_replace == other.copy_on_replace? &&
                    @once == other.once? &&
                    block == other.block
            end
        end

	# call-seq:
        #   on { |event| ... }
        #   on(:on_replace => :forward) { |event| ... }
        #
        # Adds an event handler on this generator. The block gets an Event
        # object which describes the parameters of the emission (context value,
        # time, ...). See Event for details.
        #
        # The :on_replace option governs what will happen with this handler if
        # this task is replaced by another.
        #
        # * if set to :drop, the handler is not passed on
        # * if set to :forward, the handler is added to the replacing task
        #
	def on(options = Hash.new, &handler)
	    if !options.kind_of?(Hash)
                Roby.error_deprecated "EventGenerator#on only accepts event handlers now. Use #signals to establish signalling"
	    end

            options = Kernel.validate_options options, :on_replace => :drop, :once => false
            if ![:drop, :copy].include?(options[:on_replace])
                raise ArgumentError, "wrong value for the :on_replace option. Expecting either :drop or :copy, got #{options[:on_replace]}"
            end

	    if handler
		check_arity(handler, 1)
		self.handlers << EventHandler.new(handler, options[:on_replace] == :copy, options[:once])
	    end

	    self
	end

        def initialize_replacement(event)
            super

            for h in handlers
                if h.copy_on_replace?
                    event.on(h.as_options, &h.block)
                end
            end
        end

	# Adds a signal from this event to +generator+. +generator+ must be
	# controlable.
        #
        # If +time+ is given it is either a :delay => time association, or a
        # :at => time association. In the first case, +time+ is a floating-point
        # delay in seconds and in the second case it is a Time object which is
        # the absolute point in time at which this propagation must happen.
        def signals(generator, timespec = nil)
	    if !generator.controlable?
		raise EventNotControlable.new(self), "trying to establish a signal from #{self} to #{generator} which is not controllable"
	    end
	    timespec = ExecutionEngine.validate_timespec(timespec)

	    add_signal generator, timespec
	    self
        end

	def signal(generator, timespec = nil)
            Roby.warn_deprecated "EventGenerator#signal has been renamed into EventGenerator#signals"
            signals(generator, timespec)
	end

	# A set of blocks called when this event cannot be emitted again
	attr_reader :unreachable_handlers

	# Calls +block+ if it is impossible that this event is ever emitted
	def if_unreachable(cancel_at_emission = false, &block)
            check_arity(block, 2)
            if unreachable_handlers.any? { |cancel, b| b == block }
                return b.object_id
            end
	    unreachable_handlers << [cancel_at_emission, block]
	    block.object_id
	end

        # React to this event being unreachable
        #
        # If a block is given, that block will be called when the event becomes
        # unreachable. Otherwise, the method returns an EventGenerator instance
        # which will be emitted when it happens.
        #
        # The +cancel_at_emission+ flag controls if the block (resp. event)
        # should still be called (resp. emitted) after +self+ has been emitted.
        # If true, the handler will be removed if +self+ emits. If false, the
        # handler will be kept.
        def when_unreachable(cancel_at_emission = false, &block)
            if block_given?
                return if_unreachable(cancel_at_emission, &block)
            end

            # NOTE: the unreachable event is not directly tied to this one from
            # a GC point of view (being able to do this would be useful, but
            # anyway). So, it is possible that it is GCed because the event
            # user did not take care to use it.
            if !@unreachable_events[cancel_at_emission] || !@unreachable_events[cancel_at_emission].plan
                result = EventGenerator.new(true)
                if_unreachable(cancel_at_emission) do
                    if result.plan
                        result.emit
                    end
                end
                add_causal_link result
                @unreachable_events[cancel_at_emission] = result
            end
            @unreachable_events[cancel_at_emission]
        end

	def forward(generator, timespec = nil)
            Roby.warn_deprecated "EventGenerator#forward has been renamed into EventGenerator#forward_to"
            forward_to(generator, timespec)
	end

        # Emit +generator+ when +self+ is fired, without calling the command of
        # +generator+, if any.
        #
        # If +timespec+ is given it is either a :delay => time association, or a
        # :at => time association. In the first case, +time+ is a floating-point
        # delay in seconds and in the second case it is a Time object which is
        # the absolute point in time at which this propagation must happen.
        def forward_to(generator, timespec = nil)
	    timespec = ExecutionEngine.validate_timespec(timespec)
	    add_forwarding generator, timespec
	    self
        end

	# Returns an event which is emitted +seconds+ seconds after this one
	def delay(seconds)
	    if seconds == 0 then self
	    else
		ev = EventGenerator.new
		forward_to(ev, :delay => seconds)
		ev
	    end
	end

        # Signals the given target event only once
	def signals_once(signal, delay = nil)
            signals(signal, delay)
            once do |context|
		remove_signal signal
	    end
            self
        end

	# call-seq:
        #   once { |context| ... }
        #
        # Calls the provided event handler only once
	def once(options = Hash.new, &block)
            on(options.merge(:once => true), &block)
            self
	end

        def forward_once(ev, delay = nil)
            Roby.warn_deprecated "#forward_once has been renamed into #forward_to_once"
            forward_to_once(ev)
        end

	# Forwards to the given target event only once
	def forward_to_once(ev, delay = nil)
	    forward_to(ev, delay)
	    once do |context|
		remove_forwarding ev
	    end
            self
	end

	def to_event; self end

	# Returns the set of events directly related to this one
	def related_events(result = nil); related_objects(nil, result) end
        # Returns the set of tasks that are directly linked to this events.
        #
        # I.e. it returns the tasks that have events which are directly related
        # to this event, self.task excluded:
        #
        #   ev = task.intermediate_event
        #   ev.related_tasks # => #<ValueSet: {}>
        #   ev.add_signal task2.intermediate_event
        #   ev.related_tasks # => #<ValueSet: {task2}>
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
        def new(context, propagation_id = nil, time = nil) # :nodoc:
            event_model.new(self, propagation_id || plan.engine.propagation_id, context, time || Time.now)
        end

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
		@happened = true
                @pending = false
		fired(event)

		each_signal do |signalled|
		    add_propagation(false, event, signalled, event.context, self[signalled, EventStructure::Signal])
		end
		each_forwarding do |signalled|
		    add_propagation(true, event, signalled, event.context, self[signalled, EventStructure::Forwarding])
		end

		call_handlers(event)
	    end
	end

	private :fire
	
	# Call the event handlers defined for this event generator
	def call_handlers(event)
	    # Since we are in a gathering context, call
	    # to other objects are not done, but gathered in the 
	    # :propagation TLS
            all_handlers = enum_for(:each_handler).to_a
	    all_handlers.each do |h| 
		begin
		    h.block.call(event)
                rescue LocalizedError => e
                    plan.engine.add_error( e )
		rescue Exception => e
		    plan.engine.add_error( EventHandlerError.new(e, event) )
		end
	    end
            handlers.delete_if { |h| h.once? }
	end

	# Raises an exception object when an event whose command has been
	# called won't be emitted (ever)
	def emit_failed(error = nil, message = nil)
	    error ||= EmissionFailed

	    if !message && !(error.kind_of?(Class) || error.kind_of?(Exception))
		message = error.to_str
		error = EmissionFailed
	    end

	    failure_message =
                if message then "failed to emit #{self}: #{message}"
                elsif error.respond_to?(:message) then "failed to emit #{self}: #{error.message}"
                else "failed to emit #{self}: #{message}"
                end

            if Class === error 
                error = error.new(nil, self)
                error.set_backtrace caller(1)
            end

	    new_error = error.exception failure_message
            new_error.set_backtrace error.backtrace
            error = new_error

            if !error.kind_of?(LocalizedError)
                error = EmissionFailed.new(error, self)
            end

            failed_to_emit(error)
            plan.engine.add_error(error)
	ensure
	    @pending = false
	end

        # Hook called in emit_failed to announce that the event failed to emit
        def failed_to_emit(error); super if defined? super end

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
            if @pending_sources
                event.add_sources(@pending_sources)
                @pending_sources = nil
            end
            event
        ensure
            @pending = false
	end

	# Emit the event with +context+ as the event context
	def emit(*context)
            check_emission_validity

            # This test must not be done in #emit_without_propagation as the
            # other ones: it is possible, using Distributed.update, to disable
            # ownership tests, but that does not work if the test is in
            # #emit_without_propagation
	    if !self_owned?
		raise OwnershipError, "cannot emit an event we don't own. #{self} is owned by #{owners}"
            end

	    context.compact!
            engine = plan.engine
	    if engine.gathering?
                if @calling_command
                    @command_emitted = true
                end

		engine.add_event_propagation(true, engine.propagation_sources, self, (context unless context.empty?), nil)
            else
		Roby.synchronize do
                    seeds = engine.gather_propagation do
			engine.add_event_propagation(true, engine.propagation_sources, self, (context unless context.empty?), nil)
                    end
		    engine.process_events_synchronous(seeds)
                    if unreachable? && unreachability_reason.kind_of?(Exception)
                        raise unreachability_reason
                    end
		end
	    end
	end

	# Deprecated. Instead of using
	#   dest.emit_on(source)
	# now use
	#   source.forward_to(dest)
	def emit_on(generator, timespec = nil)
            Roby.warn_deprecated "a.emit_on(b) has been replaced by b.forward_to(a)"
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
	    if block_given?
		ev.add_causal_link self
		ev.once do |context|
		    self.emit(yield(context))
		end
	    else
		ev.forward_to_once self
	    end

	    ev.if_unreachable(true) do |reason, event|
		emit_failed(EmissionFailed.new(UnreachableEvent.new(ev, reason), self))
	    end
	end
	# For backwards compatibility. Use #achieve_with.
	def realize_with(task); achieve_with(task) end

	# A [time, event] array of past event emitted by this object
	attr_reader :history
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
	    generator.signals self
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
        #
        # Example:
        #
        #   base = task1.intermediate_event
        #   filtered = base.filter(10)
        #
        #   base.on { |base_ev| ... }
        #   filtered.on { |filtered_ev| ... }
        #
        #   base.emit(20)
        #   # base_ev.context is [20]
        #   # filtered_ev.context is [10]
        #
        # The returned value is a FilterGenerator instance which is the child of
        # +self+ in the signalling relation
	def filter(*new_context, &block)
	    filter = FilterGenerator.new(new_context, &block)
	    self.signals(filter)
	    filter
	end

	# Returns a new event generator which emits until the +limit+ event is
	# sent
	#
	#   source, target, limit = (1..3).map { EventGenerator.new(true) }
	#   until = target.until(limit).on { |ev| STDERR.puts "FIRED !!!" }
	#   source.signals target
	#
	# Will do
	#
	#   source.call # => target is emitted
	#   limit.emit
	#   source.call # => target is not emitted anymore
	#
	# It returns an instance of UntilGenerator with +self+ as parent in the
        # forwarding relation and +limit+ as parent in the signalling relation.
        #
        # Alternatively, the limitation can be triggered by calling the event's
        # command explicitely:
        #
	#   source.call # => target is emitted
	#   until.call
	#   source.call # => target is not emitted anymore
        #   
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

        # Called when the object has been removed from its plan
        def finalized!(timestamp = nil)
            super
            EventGenerator.event_gathering.delete(self)
            unreachable_handlers.clear
        end

        # True if this event is unreachable, i.e. if it will never be emitted
        # anymore
	attr_predicate :unreachable?

        # If the event became unreachable, this holds the reason for its
        # unreachability, if that reason is known. This reason is always an
        # Event instance which represents the emission that triggered this
        # unreachability.
        attr_reader :unreachability_reason

        # Internal helper for unreachable!
        def call_unreachable_handlers(reason) # :nodoc:
	    unreachable_handlers.each do |_, block|
		begin
		    block.call(reason, self)
                rescue LocalizedError => e
                    if engine
                        engine.add_error(e)
                    else raise
                    end
		rescue Exception => e
                    if engine
                        engine.add_error(EventHandlerError.new(e, self))
                    else raise
                    end
		end
	    end
	    unreachable_handlers.clear
        end

        def unreachable_without_propagation(reason = nil, plan = self.plan)
	    return if @unreachable
	    @unreachable = true
            @unreachability_reason = reason

            EventGenerator.event_gathering.delete(self)
            if plan && (engine = plan.engine)
                engine.unreachable_event(self)
            end
            call_unreachable_handlers(reason)
        end

	# Called internally when the event becomes unreachable
	def unreachable!(reason = nil, plan = self.plan)
            if !plan || !plan.engine
                unreachable_without_propagation(reason)
            elsif engine.gathering?
                unreachable_without_propagation(reason, plan)
            elsif !@unreachable
		Roby.synchronize do
		    engine.process_events_synchronous do
                        unreachable_without_propagation(reason, plan)
                    end
                    if unreachability_reason.kind_of?(Exception)
                        raise unreachability_reason
                    end
		end
            end
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


    # Modifies an event context
    #
    # See EventGenerator#filter for details
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

    # Combine event generators using an AND. The generator will emit once all
    # its source events have emitted, and become unreachable if any of its
    # source events have become unreachable.
    #
    # For instance,
    #
    #    a = task1.start_event
    #    b = task2.start_event
    #    (a & b) # will emit when both tasks have started
    #
    # And events will emit only once, unless #reset is called:
    #
    #    a = task1.intermediate_event
    #    b = task2.intermediate_event
    #    and_ev = (a & b)
    #
    #    a.intermediate_event!
    #    b.intermediate_event! # and_ev emits here
    #    a.intermediate_event!
    #    b.intermediate_event! # and_ev does *not* emit
    #
    #    and_ev.reset
    #    a.intermediate_event!
    #    b.intermediate_event! # and_ev emits here
    #
    # The AndGenerator tracks its sources via the signalling relations, so
    #
    #    and_ev << c.intermediate_event
    #
    # is equivalent to
    #
    #    c.intermediate_event.add_signal and_ev
    #
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

	# After this call, the AndGenerator will emit as soon as all its source
        # events have been emitted again.
        #
        # Example:
        #    a = task1.intermediate_event
        #    b = task2.intermediate_event
        #    and_ev = (a & b)
        #
        #    a.intermediate_event!
        #    b.intermediate_event! # and_ev emits here
        #    a.intermediate_event!
        #    b.intermediate_event! # and_ev does *not* emit
        #
        #    and_ev.reset
        #    a.intermediate_event!
        #    b.intermediate_event! # and_ev emits here
	def reset
	    @active = true
	    each_parent_object(EventStructure::Signal) do |source|
		@events[source] = source.last
		if source.respond_to?(:reset)
		    source.reset
		end
	    end
	end

        # Helper method that will emit the event if all the sources are emitted.
	def emit_if_achieved(context) # :nodoc:
	    return unless @active
	    each_parent_object(EventStructure::Signal) do |source|
		return if @events[source] == source.last
	    end
	    @active = false
	    emit(nil)
	end

        # True if the generator has no sources
	def empty?; events.empty? end
	
	# Adds a new source to +events+ when a source event is added
	def added_parent_object(parent, relations, info) # :nodoc:
	    super if defined? super
	    return unless relations.include?(EventStructure::Signal)
	    @events[parent] = parent.last

	    # If the parent is unreachable, check that it has neither been
	    # removed, nor it has been emitted
	    parent.if_unreachable(true) do |reason, event|
		if @events.has_key?(parent) && @events[parent] == parent.last
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
        # The set of generators that have not been emitted yet.
	def waiting; parent_objects(EventStructure::Signal).find_all { |ev| @events[ev] == ev.last } end
	
	# Add a new source to this generator
	def << (generator)
	    generator.add_signal self
	    self
	end
    end

    # Fires when the first of its source events fires.
    #
    # For instance,
    #
    #    a = task1.start_event
    #    b = task2.start_event
    #    (a | b) # will emit as soon as one of task1 and task2 are started
    #
    # Or events will emit only once, unless #reset is called:
    #
    #    a = task1.intermediate_event
    #    b = task2.intermediate_event
    #    or_ev = (a | b)
    #
    #    a.intermediate_event! # or_ev emits here
    #    b.intermediate_event! # or_ev does *not* emit 
    #    a.intermediate_event! # or_ev does *not* emit
    #    b.intermediate_event! # or_ev does *not* emit
    #
    #    or_ev.reset
    #    b.intermediate_event! # or_ev emits here
    #    a.intermediate_event! # or_ev does *not* emit
    #    b.intermediate_event! # or_ev does *not* emit
    #
    # The OrGenerator tracks its sources via the signalling relations, so
    #
    #    or_ev << c.intermediate_event
    #
    # is equivalent to
    #
    #    c.intermediate_event.add_signal or_ev
    #
    class OrGenerator < EventGenerator
        # Creates a new OrGenerator without any sources.
	def initialize
	    super do |context|
		emit_if_first(context)
	    end
	    @active = true
	end

        # True if there is no source events
	def empty?; parent_objects(EventStructure::Signal).empty? end

        # Or generators will emit only once, unless this method is called. See
        # the documentation of OrGenerator for an example.
	def reset
	    @active = true
	    each_parent_object(EventStructure::Signal) do |source|
		if source.respond_to?(:reset)
		    source.reset
		end
	    end
	end

        # Helper method called to emit the event when it is required
	def emit_if_first(context) # :nodoc:
	    return unless @active
	    @active = false
	    emit(context)
	end

        # Tracks the event's parents in the signalling relation
	def added_parent_object(parent, relations, info) # :nodoc:
	    super if defined? super
	    return unless relations.include?(EventStructure::Signal)

	    parent.if_unreachable(true) do |reason, event|
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
		source.forward_to(self)
		limit.signals(self)
	    end
	end
    end

    unless defined? EventStructure
	EventStructure = RelationSpace(EventGenerator)
        EventStructure.default_graph_class = EventRelationGraph
    end
end

