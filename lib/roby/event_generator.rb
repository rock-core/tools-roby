module Roby
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

        def dup(plan: TemplatePlan.new)
            copy = super()
            if plan
                copy.plan = plan
                plan.register_event(copy)
            end
            copy
        end

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

        def plan=(plan)
            super
            @relation_graphs = if plan then plan.event_relation_graphs
                               end
        end

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
            plan.register_event(self)
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
		raise EventNotExecutable.new(self), "#emit called on #{self} which has been removed from its plan"
            elsif !plan.executable?
		raise EventNotExecutable.new(self), "#emit called on #{self} which is not in an executable plan"
	    elsif !controlable?
		raise EventNotControlable.new(self), "#call called on a non-controlable event"
            elsif unreachable?
                if unreachability_reason
                    raise UnreachableEvent.new(self, unreachability_reason), "#call called on #{self} which has been made unreachable because of #{unreachability_reason}"
                else
                    raise UnreachableEvent.new(self, unreachability_reason), "#call called on #{self} which has been made unreachable"
                end
            elsif !engine.allow_propagation?
                raise PhaseMismatch, "call to #emit is not allowed in this context"
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
                seeds = engine.gather_propagation do
                    engine.add_event_propagation(false, engine.propagation_sources, self, (context unless context.empty?), nil)
                end
                engine.process_events_synchronous(seeds)
                if unreachable? && unreachability_reason.kind_of?(Exception)
                    raise unreachability_reason
                end
	    end
	end

        # Class used to register event handler blocks along with their options
        class EventHandler
            attr_reader :block
            
            def initialize(block, copy_on_replace, once)
                @block, @copy_on_replace, @once = block, copy_on_replace, once
            end

            def call(*args)
                block.call(*args)
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

                { on_replace: mode, once: once? }
            end

            def ==(other)
                @copy_on_replace == other.copy_on_replace? &&
                    @once == other.once? &&
                    block == other.block
            end
        end

	# call-seq:
        #   on { |event| ... }
        #   on(on_replace: :forward) { |event| ... }
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
            elsif !handler
                raise ArgumentError, "no block given"
	    end

            options = Kernel.validate_options options, on_replace: :drop, once: false
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

            for h in unreachable_handlers
                cancel, h = h
                if h.copy_on_replace?
                    event.if_unreachable(cancel_at_emission: cancel, on_replace: :copy, &h.block)
                end
            end
        end

	# Adds a signal from this event to +generator+. +generator+ must be
	# controlable.
        #
        # If +time+ is given it is either a delay: time association, or a
        # at: time association. In the first case, +time+ is a floating-point
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
        #
        # @return [Array<(Boolean,EventHandler)>]
	attr_reader :unreachable_handlers

	# Calls +block+ if it is impossible that this event is ever emitted
        #
        # @option options [Boolean] :cancel_at_emission (false) if true, the
        #   block will only be called if the event did not get emitted since the
        #   handler got installed.
        # @option options [:drop,:copy] :on_replace (:drop) if set to drop, the
        #   block will not be passed to events that replace this one. Otherwise,
        #   the block gets copied
        #
        # @yieldparam [Object] reason the unreachability reason (usually an
        #   exception)
        # @yieldparam [EventGenerator] generator the event generator that became
        #   unreachable. This is needed when the :on_replace option is :copy,
        #   since the generator that became unreachable might be different than
        #   the one on which the handler got installed
	def if_unreachable(options = Hash.new, &block)
            if options == true || options == false
                options = Hash[cancel_at_emission: options]
            end
            options = Kernel.validate_options options,
                cancel_at_emission: false,
                on_replace: :drop

            if ![:drop, :copy].include?(options[:on_replace])
                raise ArgumentError, "wrong value for the :on_replace option. Expecting either :drop or :copy, got #{options[:on_replace]}"
            end

            check_arity(block, 2)
            if unreachable_handlers.any? { |cancel, b| b.block == block }
                return b.object_id
            end
            handler = EventHandler.new(block, options[:on_replace] == :copy, true)
	    unreachable_handlers << [options[:cancel_at_emission], handler]
	    handler.object_id
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
                return if_unreachable(cancel_at_emission: cancel_at_emission, &block)
            end

            # NOTE: the unreachable event is not directly tied to this one from
            # a GC point of view (being able to do this would be useful, but
            # anyway). So, it is possible that it is GCed because the event
            # user did not take care to use it.
            if !@unreachable_events[cancel_at_emission] || !@unreachable_events[cancel_at_emission].plan
                result = EventGenerator.new(true)
                if_unreachable(cancel_at_emission: cancel_at_emission) do
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
        # If +timespec+ is given it is either a delay: time association, or a
        # at: time association. In the first case, +time+ is a floating-point
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
		forward_to(ev, delay: seconds)
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
            on(options.merge(once: true), &block)
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
        #   ev.related_tasks # => #<Set: {}>
        #   ev.add_signal task2.intermediate_event
        #   ev.related_tasks # => #<Set: {task2}>
	def related_tasks(result = nil)
	    result ||= Set.new
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
		    h.call(event)
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
                if message then message
                elsif error.respond_to?(:message) then error.message
                else "failed to emit #{self}"
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
                seeds = engine.gather_propagation do
                    engine.add_event_propagation(true, engine.propagation_sources, self, (context unless context.empty?), nil)
                end
                engine.process_events_synchronous(seeds)
                if unreachable? && unreachability_reason.kind_of?(Exception)
                    raise unreachability_reason
                end
	    end
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

	    ev.if_unreachable(cancel_at_emission: true) do |reason, event|
		emit_failed(EmissionFailed.new(UnreachableEvent.new(ev, reason), self))
	    end
	end
	# For backwards compatibility. Use #achieve_with.
	def realize_with(task); achieve_with(task) end

        # Declares that the command of this event should be achieved by calling
        # the provided block
        #
        # @option [Boolean] :emit_on_success (true) if true, the event will be
        #   emitted if the block got called successfully. Otherwise, nothing
        #   will be done
        # @option [#call] :callback (nil) if given, it gets called in Roby's
        #   event thread with the return value of the block as argument if the
        #   block got called successfully
        def achieve_asynchronously(options = Hash.new, &block)
            options = Kernel.validate_options options,
                emit_on_success: true,
                callback: proc { }

            worker_thread = Thread.new do
                begin
                    result = block.call
                    if engine
                        engine.queue_worker_completion_block do |plan|
                            begin
                                options[:callback].call(result)
                                if options[:emit_on_success]
                                    emit
                                end
                            rescue Exception => e
                                emit_failed(e)
                            end
                        end
                    end

                rescue Exception => e
                    if engine
                        engine.queue_worker_completion_block do |plan|
                            emit_failed(e)
                        end
                    end
                end
            end
            engine.register_worker_thread(worker_thread)
            worker_thread
        end

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

        # Hook called when this object has been created inside a transaction and
        # should be modified to now apply on the transaction's plan
        def commit_transaction
	    super if defined? super
        end

        def added_child_object(child, relations, info) # :nodoc:
            super if defined? super
            plan.added_event_relation(self, child, relations)
        end

        def removed_child_object(child, relations) # :nodoc:
            super if defined? super
            plan.removed_event_relation(self, child, relations)
        end

        # Called when the object has been removed from its plan
        def finalized!(timestamp = nil)
            super
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
	    unreachable_handlers.each do |_, handler|
		begin
		    handler.call(reason, self)
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

            if engine = plan.execution_engine
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
                engine.process_events_synchronous do
                    unreachable_without_propagation(reason, plan)
                end
                if unreachability_reason.kind_of?(Exception)
                    raise unreachability_reason
                end
            end
	end

	def pretty_print(pp) # :nodoc:
	    pp.text to_s
	    pp.group(2, ' {', '}') do
		pp.breakable
		pp.text "owners: "
		pp.seplist(owners) { |r| pp.text r.to_s }
	    end
	end

        def to_execution_exception
            LocalizedError.new(self).to_execution_exception
        end

        def to_execution_exception_matcher
            LocalizedError.to_execution_exception_matcher.with_origin(self)
        end

        def match
            Queries::TaskEventGeneratorMatcher.new(task, symbol)
        end
    end

    unless defined? EventStructure
	EventStructure = RelationSpace(EventGenerator)
        EventStructure.default_graph_class = Relations::EventRelationGraph
    end
end

