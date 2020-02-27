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
    # * #calling
    # * #called
    # * #fired
    # * #signalling
    # * #forwarding
    #
    class EventGenerator < PlanObject
        class << self
            attr_reader :relation_spaces
            attr_reader :all_relation_spaces
        end
        @relation_spaces = Array.new
        @all_relation_spaces = Array.new

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
            @emitted = old.emitted?
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

        attr_predicate :pending?, true

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
        def initialize(command_object = nil, controlable: false, plan: TemplatePlan.new, &command_block)
            @preconditions   = []
            @handlers        = []
            @pending         = false
            @pending_sources = []
            @unreachable     = false
            @unreachable_events   = Hash.new
            @unreachable_handlers = []
            @history       = Array.new
            @event_model = Event

            command_object ||= controlable

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
            super(plan: plan)
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
                EventNotExecutable.new(self).
                    exception("#emit called on #{self} which has been removed from its plan")
            elsif !plan.executable?
                EventNotExecutable.new(self).
                    exception("#emit called on #{self} which is not in an executable plan")
            elsif !controlable?
                EventNotControlable.new(self).
                    exception("#call called on a non-controlable event")
            elsif unreachable?
                if unreachability_reason
                    UnreachableEvent.new(self, unreachability_reason).
                        exception("#call called on #{self} which has been made unreachable because of #{unreachability_reason}")
                else
                    UnreachableEvent.new(self, unreachability_reason).
                        exception("#call called on #{self} which has been made unreachable")
                end
            elsif !execution_engine.allow_propagation?
                PhaseMismatch.exception("call to #emit is not allowed in this context")
            elsif !execution_engine.inside_control?
                ThreadMismatch.exception("#call called while not in control thread")
            end
        end

        def check_call_validity_after_calling
            if !executable?
                EventNotExecutable.new(self).
                    exception("#call called on #{self} which is a non-executable event")
            end
        end

        # Checks that the event can be emitted. Raises various exception
        # when it is not the case.
        def check_emission_validity
            if !plan
                EventNotExecutable.new(self).
                    exception("#emit called on #{self} which has been removed from its plan")
            elsif !plan.executable?
                EventNotExecutable.new(self).
                    exception("#emit called on #{self} which is not in an executable plan")
            elsif !executable?
                EventNotExecutable.new(self).
                    exception("#emit called on #{self} which is a non-executable event")
            elsif unreachable?
                if unreachability_reason
                    UnreachableEvent.new(self, unreachability_reason).
                        exception("#emit called on #{self} which has been made unreachable because of #{unreachability_reason}")
                else
                    UnreachableEvent.new(self, unreachability_reason).
                        exception("#emit called on #{self} which has been made unreachable")
                end
            elsif !execution_engine.allow_propagation?
                PhaseMismatch.exception("call to #emit is not allowed in this context")
            elsif !execution_engine.inside_control?
                ThreadMismatch.exception("#emit called while not in control thread")
            end
        end

        # Calls the command from within the event propagation code
        def call_without_propagation(context)
            if error = check_call_validity
                clear_pending
                execution_engine.add_error(error)
                return
            end

            calling(context)

            if (error = check_call_validity) || (error = check_call_validity_after_calling)
                clear_pending
                execution_engine.add_error(error)
                return
            end

            begin
                @calling_command = true
                @command_emitted = false
                execution_engine.propagation_context([self]) do
                    command.call(context)
                end

            rescue Exception => e
                if !e.kind_of?(LocalizedError)
                    e = CommandFailed.new(e, self)
                end
                if command_emitted?
                    execution_engine.add_error(e)
                else
                    emit_failed(e)
                end

            ensure
                @calling_command = false
            end
            called(context)
        end

        # Right after a call to #call_without_propagation, tells the caller
        # whether the command has emitted or not. This can be used to determine
        # in which context errors should be raised
        attr_predicate :command_emitted?, false

        # Call the command associated with self. Note that an event might be
        # non-controlable and respond to the :call message. Controlability must
        # be checked using #controlable?
        def call(*context)
            engine = execution_engine
            if engine && !engine.in_propagation_context?
                Roby.warn_deprecated "calling EventGenerator#call outside of propagation context is deprecated. In tests, use execute { } or expect_execution { }.to { }"
                engine.process_events_synchronous { call(*context) }
                return
            end

            if error = check_call_validity
                clear_pending
                raise error
            end

            # This test must not be done in #emit_without_propagation as the
            # other ones: it is possible, using Distributed.update, to disable
            # ownership tests, but that does not work if the test is in
            # #emit_without_propagation
            if !self_owned?
                raise OwnershipError, "not owner"
            end

            execution_engine.queue_signal(engine.propagation_sources, self, context, nil)
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
        def on(on_replace: :drop, once: false, &handler)
            if ![:drop, :copy].include?(on_replace)
                raise ArgumentError, "wrong value for the :on_replace option. Expecting either :drop or :copy, got #{on_replace}"
            end
            check_arity(handler, 1)
            self.handlers << EventHandler.new(handler, on_replace == :copy, once)
            self
        end

        def initialize_replacement(event, &block)
            for h in handlers
                if h.copy_on_replace?
                    event ||= yield
                    event.on(h.as_options, &h.block)
                end
            end

            for h in unreachable_handlers
                cancel, h = h
                if h.copy_on_replace?
                    event ||= yield
                    event.if_unreachable(cancel_at_emission: cancel, on_replace: :copy, &h.block)
                end
            end

            if event
                super(event)
            else super(nil, &block)
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
                Roby.warn_deprecated "if_unreachable(cancel_at_emission) has been replaced by if_unreachable(cancel_at_emission: true or false, on_replace: :policy)"
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
        def related_events(result = Set.new); related_objects(nil, result) end
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
            event_model.new(self, propagation_id || execution_engine.propagation_id,
                            context, time || Time.now)
        end

        # Do fire this event. It gathers the list of signals that are to
        # be propagated in the next step and calls fired()
        #
        # This method is always called in a propagation context
        def fire(event)
            @emitted = true
            clear_pending
            fired(event)

            execution_engine = self.execution_engine

            signal_graph = execution_engine.signal_graph
            each_signal do |target|
                if self == target
                    raise PropagationError, "#{self} is trying to signal itself"
                end
                execution_engine.queue_signal([event], target, event.context,
                                              signal_graph.edge_info(self, target))
            end

            forward_graph = execution_engine.forward_graph
            each_forwarding do |target|
                if self == target
                    raise PropagationError, "#{self} is trying to signal itself"
                end
                execution_engine.queue_forward([event], target, event.context,
                                               forward_graph.edge_info(self, target))
            end

            execution_engine.propagation_context([event]) do
                call_handlers(event)
            end
        end

        # Call the event handlers defined for this event generator
        def call_handlers(event)
            # Since we are in a gathering context, call
            # to other objects are not done, but gathered in the
            # :propagation TLS
            all_handlers = enum_for(:each_handler).to_a
            processed_once_handlers = all_handlers.find_all do |h|
                begin
                    h.call(event)
                rescue LocalizedError => e
                    execution_engine.add_error( e )
                rescue Exception => e
                    execution_engine.add_error( EventHandlerError.new(e, event) )
                end
                h.once?
            end
            handlers.delete_if { |h| processed_once_handlers.include?(h) }
        end

        # Raises an exception object when an event whose command has been
        # called won't be emitted (ever)
        def emit_failed(error = nil, message = nil)
            engine = execution_engine
            if engine && !engine.in_propagation_context?
                Roby.warn_deprecated "calling EventGenerator#emit_failed outside of propagation context is deprecated. In tests, use execute { } or expect_execution { }.to { }"
                engine.process_events_synchronous { emit_failed(error, message) }
                return
            end

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

            execution_engine.log(:generator_emit_failed, self, error)
            execution_engine.add_error(error)
            error
        ensure
            clear_pending
        end

        # Emits the event regardless of wether we are in a propagation context
        # or not. Returns true to match the behavior of #call_without_propagation
        #
        # This is used by event propagation. Do not call directly: use #call instead
        def emit_without_propagation(context)
            if error = check_emission_validity
                execution_engine.add_error(error)
                return
            end

            emitting(context)

            # Create the event object
            event = new(context)
            if !event.respond_to?(:add_sources)
                raise TypeError, "#{event} is not a valid event object in #{self}"
            end
            event.add_sources(execution_engine.propagation_source_events)
            event.add_sources(@pending_sources)
            fire(event)
            event
        ensure
            clear_pending
        end

        # Emit the event with +context+ as the event context
        def emit(*context)
            engine = execution_engine
            if engine && !engine.in_propagation_context?
                Roby.warn_deprecated "calling EventGenerator#emit outside of propagation context is deprecated. In tests, use execute { } or expect_execution { }.to { }"
                engine.process_events_synchronous { emit(*context) }
                return
            end

            if error = check_emission_validity
                clear_pending
                raise error
            end

            # This test must not be done in #emit_without_propagation as the
            # other ones: it is possible, using Distributed.update, to disable
            # ownership tests, but that does not work if the test is in
            # #emit_without_propagation
            if !self_owned?
                raise OwnershipError, "cannot emit an event we don't own. #{self} is owned by #{owners}"
            end

            if @calling_command
                @command_emitted = true
            end

            engine.queue_forward(
                engine.propagation_sources, self, context, nil)
        end

        # Set this generator up so that it "delegates" its emission to another
        # event
        #
        # @overload achieve_with(generator)
        #   Emit self next time generator is emitted, and mark it as unreachable
        #   if generator is. The event context is propagated through.
        #
        #   @param [EventGenerator] generator
        #
        # @overload achieve_with(generator) { |event| ... }
        #   Emit self next time generator is emitted, and mark it as unreachable
        #   if generator is. The value returned by the block is used as self's
        #   event context
        #
        #   An exception raised by the filter will be localized on self.
        #
        #   @param [EventGenerator] generator
        #   @yieldparam [Event] event the event emitted by 'generator'
        #   @yieldreturn [Object] the context to be used for self's event
        def achieve_with(ev)
            if block_given?
                ev.add_causal_link self
                ev.once do |event|
                    begin
                        context = yield(event)
                        do_emit = true
                    rescue Exception => e
                        emit_failed(e)
                    end
                    if do_emit
                        self.emit(context)
                    end
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
        # @param [Boolean] emit_on_success if true, the event will be emitted if
        #   the block got called successfully. Otherwise, nothing will be done.
        # @param [Promise] a promise object that represents the work. Use
        #   {ExecutionEngine#promise} to create this promise.
        # @param [Proc,nil] block a block from which the method will create a
        #   promise. This promise is *not* returned as it would give a false
        #   sense of security.
        # @param [Symbol] on_failure controls what happens if the promise fails.
        #   With the default of :fail, the event generator's emit_failed is
        #   called. If it is :emit, it gets emitted. If it is :nothing,
        #   nothing's done
        #
        # @return [Promise] the promise. Do NOT chain work on this promise, as
        #   that work won't be automatically error-checked by Roby's mechanisms
        def achieve_asynchronously(promise = nil, description: "#{self}#achieve_asynchronously", emit_on_success: true, on_failure: :fail, context: nil, &block)
            if promise && block
                raise ArgumentError, "cannot give both a promise and a block"
            elsif ![:fail, :emit, :nothing].include?(on_failure)
                raise ArgumentError, "expected on_failure to either be :fail or :emit"
            elsif block
                promise = execution_engine.promise(description: description, &block)
            end

            if promise.null?
                emit(*context) if emit_on_success
                return
            end

            if emit_on_success
                promise.on_success(description: "#{self}.emit") { emit(*context) }
            end
            if on_failure != :nothing
                promise.on_error(description: "#{self}#emit_failed") do |reason|
                    if on_failure == :fail
                        emit_failed(reason)
                    elsif on_failure == :emit
                        emit(*context)
                    end
                end
            end
            promise.execute
            promise
        end

        # A [time, event] array of past event emitted by this object
        attr_reader :history
        # True if this event has been emitted once.
        attr_predicate :emitted?
        # True if this event has been emitted once.
        def happened?
            Roby.warn_deprecated "#happened? is deprecated, use #emitted? instead"
            emitted?
        end
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

        # Call this method in the #calling hook to cancel calling the event
        # command. This raises an EventCanceled exception with +reason+ for
        # message
        def cancel(reason = nil)
            raise EventCanceled.new(self), (reason || "event canceled")
        end

        def pending(sources)
            @pending = true
            @pending_sources.concat(sources)
        end

        def clear_pending
            @pending = false
            @pending_sources = []
        end

        # Hook called when this event generator is called (i.e. the associated
        # command is), before the command is actually called. Think of it as a
        # pre-call hook.
        def calling(context)
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
        def called(context)
        end

        # Hook called when this event will be emitted
        def emitting(context)
        end

        # Hook called when this generator has been fired. +event+ is the Event object
        # which has been created.
        def fired(event)
            unreachable_handlers.delete_if { |cancel, _| cancel }
            history << event
            execution_engine.log(:generator_fired, event)
        end

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
            if !child.read_write?
                raise OwnershipError, "cannot add an event relation on a child we don't own. #{child} is owned by #{child.owners.to_a} (plan is owned by #{plan.owners.to_a if plan})"
            end

            super
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
        # unreachability, if that reason is known.
        attr_reader :unreachability_reason

        # Internal helper for unreachable!
        def call_unreachable_handlers(reason) # :nodoc:
            unreachable_handlers.each do |_, handler|
                begin
                    handler.call(reason, self)
                rescue LocalizedError => e
                    execution_engine.add_error(e)
                rescue Exception => e
                    execution_engine.add_error(EventHandlerError.new(e, self))
                end
            end
            unreachable_handlers.clear
        end

        def unreachable_without_propagation(reason = nil, plan = self.plan)
            return if @unreachable
            mark_unreachable!(reason)

            execution_engine.log(:generator_unreachable, self, reason)
            if execution_engine
                execution_engine.unreachable_event(self)
            end
            call_unreachable_handlers(reason)
        end

        def mark_unreachable!(reason)
            clear_pending
            @unreachable = true
            @unreachability_reason = reason
        end

        # @api private
        #
        # Called if the event has been garbage-collected, but cannot be
        # finalized yet (possibly because {#can_finalize?} returns false)
        def garbage!
            super
            unreachable!
        end

        # Called internally when the event becomes unreachable
        def unreachable!(reason = nil, plan = self.plan)
            engine = execution_engine
            if engine && !engine.in_propagation_context?
                Roby.warn_deprecated "calling EventGenerator#unreachable! outside of propagation context is deprecated. In tests, use execute { } or expect_execution { }.to { }"
                execution_engine.process_events_synchronous do
                    unreachable!(reason, plan)
                end
                return
            end

            if !plan
                raise FinalizedPlanObject, "#unreachable! called on #{self} but this is a finalized generator"
            elsif !plan.executable?
                unreachable_without_propagation(reason)
            else
                unreachable_without_propagation(reason, plan)
            end
        end

        def pretty_print(pp, context_task: nil) # :nodoc:
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


        def self.match
            Queries::EventGeneratorMatcher.new.with_model(self)
        end

        def match
            Queries::EventGeneratorMatcher.new(self)
        end

        def replace_by(object)
            plan.replace_subplan(Hash.new, Hash[object => object])
            initialize_replacement(object)
        end

        def create_transaction_proxy(transaction)
            transaction.create_and_register_proxy_event(self)
        end
    end

    unless defined? EventStructure
        EventStructure = RelationSpace(EventGenerator)
        EventStructure.default_graph_class = Relations::EventRelationGraph
    end
end
