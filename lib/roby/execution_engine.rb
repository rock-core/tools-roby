module Roby
    # Exception wrapper used to report that multiple errors have been raised
    # during a synchronous event processing call.
    # 
    # See ExecutionEngine#process_events_synchronous for more information
    class SynchronousEventProcessingMultipleErrors < RuntimeError
        # Exceptions as gathered during propagation with {ExecutionEngine#on_exception}
        #
        # @return [Array<ExecutionEngine::ErrorPhaseResult>]
        attr_reader :errors

        # The set of underlying "real" (i.e. non-Roby) exceptions
        #
        # @return [Array<Exception>]
        def original_exceptions
            errors.flat_map { |e| e.original_exceptions }.to_set.to_a
        end

        def initialize(errors)
            @errors = errors
        end

        def pretty_print(pp)
            pp.text "Got #{errors.size} exceptions and #{original_exceptions.size} sub-exceptions"
            pp.breakable
            pp.seplist(errors.each_with_index) do |e, i|
                Roby.flatten_exception(e).each_with_index do |sub_e, sub_i|
                    pp.breakable
                    pp.text "[#{i}.#{sub_i}] "
                    sub_e.pretty_print(pp)
                end
            end
        end
    end

    # @api private
    #
    # The core execution algorithm
    #
    # It is in charge of handling event and exception propagation, as well as
    # running cleanup processes (e.g. garbage collection).
    #
    # The main method is {#process_events}. When executing a Roby application,
    # it is called periodically by {#event_loop}.
    #
    # In addition, there is a special "synchronous" propagation mode that is
    # used by {EventGenerator#call} and {EventGenerator#emit}. This mode is used
    # when the event code is not executed within an engine, but from an
    # imperative script, as in unit tests.
    class ExecutionEngine
        extend Logger::Hierarchy
        include Logger::Hierarchy
        include DRoby::EventLogging

        # Whether this engine should use the OOB GC from the gctools gem
        attr_predicate :use_oob_gc?, true

        class << self
            # Whether the engines should use the OOB GC from the gctools gem by
            # default
            #
            # It is enabled in lib/roby.rb if the gctools are installed
            attr_predicate :use_oob_gc?, true
        end

        # Create an execution engine acting on +plan+, using +control+ as the
        # decision control object
        #
        # @param [ExecutablePlan] plan the plan on which this engine acts
        # @param [DecisionControl] control the policy object, i.e. the object
        #   that embeds policies in cases where multiple reactions would be
        #   possible
        # @param [DRoby::EventLogger] event_logger the logger that should be
        #   used to trace execution events. It is by default the same than the
        #   {#plan}'s. Pass a {DRoby::NullEventLogger} instance to disable event
        #   logging for this engine.
        def initialize(plan, control: Roby::DecisionControl.new, event_logger: plan.event_logger)
            @plan = plan
            @event_logger = event_logger

            @use_oob_gc = ExecutionEngine.use_oob_gc?

            @control = control
            @scheduler = Schedulers::Null.new(plan)
            @thread_pool = Concurrent::CachedThreadPool.new
            @thread = Thread.current

            @propagation = nil
            @propagation_id = 0
            @propagation_exceptions = nil
            @application_exceptions = nil
            @delayed_events = []
            @event_ordering = Array.new
            @event_priorities = Hash.new
            @propagation_handlers = []
            @external_events_handlers = []
            @at_cycle_end_handlers = Array.new
            @process_every   = Array.new
            @waiting_work = Concurrent::Array.new
            @emitted_events  = Array.new
            @disabled_handlers = Set.new
            @additional_errors = nil
            @exception_listeners = Array.new

            @worker_threads_mtx = Mutex.new
            @worker_threads = Array.new
            @once_blocks = Queue.new

	    each_cycle(&ExecutionEngine.method(:call_every))

	    @quit        = 0
            @allow_propagation = true
	    @cycle_index = 0
	    @cycle_start = Time.now
            @cycle_length = 0.1
	    @last_stop_count = 0
            @finalizers = []
            @gc_warning = true

            refresh_relations

            self.display_exceptions = true
	end

        # Refresh the value of cached relations
        #
        # Some often-used relations are cached at {#initialize}, such as
        # {#dependency_graph} and {#precedence_graph}. Call this when
        # the actual graph objects have changed on the plan
        def refresh_relations
            @dependency_graph = plan.task_relation_graph_for(TaskStructure::Dependency)
            @precedence_graph = plan.event_relation_graph_for(EventStructure::Precedence)
            @signal_graph     = plan.event_relation_graph_for(EventStructure::Signal)
            @forward_graph    = plan.event_relation_graph_for(EventStructure::Forwarding)
        end

        # A thread pool on which async work should be executed
        #
        # @see {#promise}
        # @return [Concurrent::CachedThreadPool]
        attr_reader :thread_pool

        # Cached graph object for {EventStructure::Precedence}
        #
        # This is here for performance reasons, to avoid resolving the same
        # graph over and over
        attr_reader :precedence_graph

        # Cached graph object for {EventStructure::Signal}
        #
        # This is here for performance reasons, to avoid resolving the same
        # graph over and over
        attr_reader :signal_graph

        # Cached graph object for {EventStructure::Forward}
        #
        # This is here for performance reasons, to avoid resolving the same
        # graph over and over
        attr_reader :forward_graph

        # Cached graph object for {TaskStructure::Dependency}
        #
        # This is here for performance reasons, to avoid resolving the same
        # graph over and over
        attr_reader :dependency_graph

        # The Plan this engine is acting on
        attr_accessor :plan
        # The underlying {DRoby::EventLogger}
        #
        # It is usually the same than the {#plan}'s. Pass a
        # {DRoby::NullEventLogger} at construction time to disable logging of
        # execution events.
        attr_accessor :event_logger
        # The DecisionControl object associated with this engine
        attr_accessor :control
        # A numeric ID giving the count of the current propagation cycle
        attr_reader :propagation_id
        # The set of events that have been emitted within the last call to
        # {#process_events} (i.e. the last execution of the event loop)
        #
        # @return [Array<Event>]
        attr_reader :emitted_events
        # The blocks that are currently listening to exceptions
        # @return [Array<#call>]
        attr_reader :exception_listeners
        # Thread-safe queue to push work to the execution engine
        #
        # Do not access directly, use {#once} instead
        #
        # @return [Queue] blocks that should be executed at the beginning of the
        #   next execution cycle. It is the only thread safe way to queue work
        #   to be executed by the engine
        attr_reader :once_blocks

        # @api private
        # 
        # Internal structure used to store a poll block definition provided to
        # #every or #add_propagation_handler
        class PollBlockDefinition
            ON_ERROR = [:raise, :ignore, :disable]

            attr_reader :description
            attr_reader :handler
            attr_reader :on_error
            attr_predicate :late?, true
            attr_predicate :once?, true
            attr_predicate :disabled?, true

            def id; handler.object_id end

            def initialize(description, handler, on_error: :raise, late: false, once: false)
                if !PollBlockDefinition::ON_ERROR.include?(on_error.to_sym)
                    raise ArgumentError, "invalid value '#{on_error} for the :on_error option. Accepted values are #{ON_ERROR.map(&:to_s).join(", ")}"
                end

                @description, @handler, @on_error, @late, @once =
                    description, handler, on_error, late, once
                @disabled = false
            end
        
            def to_s; "#<PollBlockDefinition: #{description} #{handler} on_error:#{on_error}>" end

            def call(engine, *args)
                handler.call(*args)
                true

            rescue Exception => e
                if on_error == :raise
                    engine.add_framework_error(e, description)
                    return false
                elsif on_error == :disable
                    ExecutionEngine.warn "propagation handler #{description} disabled because of the following error"
                    Roby.display_exception(ExecutionEngine.logger.io(:warn), e)
                    return false
                elsif on_error == :ignore
                    ExecutionEngine.warn "ignored error from propagation handler #{description}"
                    Roby.display_exception(ExecutionEngine.logger.io(:warn), e)
                    return true
                end
            end
        end

        # Add/remove propagation handler methods that are shared between the
        # instance and the class
        module PropagationHandlerMethods
            # Code blocks that get called at the beginning of each cycle
            #
            # @return [Array<PollBlockDefinition>]
            attr_reader :external_events_handlers
            # Code blocks that get called during propagation to handle some
            # internal propagation mechanism
            #
            # @return [Array<PollBlockDefinition>]
            attr_reader :propagation_handlers

            # @api private
            #
            # Helper method that gets the arguments necessary top create a
            # propagation handler, sanitizes and normalizes them, and returns
            # both the propagation type and the {PollBlockDefinition} object
            #
            # @param [:external_events,:propagation] type whether the block should be registered as an
            #   :external_events block, processed at the beginning of the cycle,
            #   or a :propagation block, processed at each propagation loop.
            # @param [String] description a string describing the block. It will
            #   be used when adding timepoints to the event log
            # @param poll_options (see PollBlockDefinition#initialize)
            def create_propagation_handler(type: :external_events, description: 'propagation handler', **poll_options, &block)
                check_arity block, 1
                handler = PollBlockDefinition.new(description, block, **poll_options)

                if type == :external_events
                    if handler.late?
                        raise ArgumentError, "only :propagation handlers can be marked as 'late', the external event handlers cannot"
                    end
                elsif type != :propagation
                    raise ArgumentError, "invalid value for the :type option. Expected :propagation or :external_events, got #{type}"
                end
                return type, handler
            end

            # The propagation handlers are blocks that should be called at
            # various places during propagation for all plans. These objects
            # are called in propagation context, which means that the events
            # they would call or emit are injected in the propagation process
            # itself.
            #
            # @param [:propagation,:external_events] type defines when this block should be called. If
            #   :external_events, it is called only once at the beginning of each
            #   execution cycle. If :propagation, it is called once at the
            #   beginning of each cycle, as well as after each propagation step.
            #   The :late option also gives some control over when the handler is
            #   called when in propagation mode
            # @option options [Boolean] once (false) if true, this handler will
            #   be removed just after its first execution
            # @option options [Boolean] late (false) if true, the handler is
            #   called only when there are no events to propagate anymore.
            # @option options [:raise,:ignore,:disable] on_error (:raise)
            #   controls what happens when the block raises an exception. If
            #   :raise, the error is registered as a framework error. If
            #   :ignore, it is completely ignored. If :disable, the handler
            #   will be disabled, i.e. not called anymore until #disabled?
            #
            # @return [Object] an ID object that can be passed to
            #   {#remove_propagation_handler}
            def add_propagation_handler(type: :external_events, description: 'propagation handler', **poll_options, &block)
                type, handler = create_propagation_handler(type: type, description: description, **poll_options, &block)
                if type == :propagation
                    propagation_handlers << handler
                elsif type == :external_events
                    external_events_handlers << handler
                end
                handler.id
            end
            
            # This method removes a propagation handler which has been added by
            # {#add_propagation_handler}.
            #
            # @param [Object] id the block ID as returned by
            #   {#add_propagation_handler}
            def remove_propagation_handler(id)
                propagation_handlers.delete_if { |p| p.id == id }
                external_events_handlers.delete_if { |p| p.id == id }
                nil
            end

            # Add a handler that is called at the beginning of the execution cycle
            def at_cycle_begin(description: 'at_cycle_begin', **options, &block)
                add_propagation_handler(description: description, type: :external_events, **options, &block)
            end

            # Execute the given block at the beginning of each cycle, in propagation
            # context.
            #
            # @return [Object] an ID that can be used to remove the handler using
            #   {#remove_propagation_handler}
            def each_cycle(description: 'each_cycle', &block)
                add_propagation_handler(description: description, &block)
            end
        end
        
        @propagation_handlers = Array.new
        @external_events_handlers = Array.new
        extend PropagationHandlerMethods
        include PropagationHandlerMethods

        # Poll blocks that have been disabled because they raised an exception
        #
        # @return [Array<PollBlockDefinition>]
        attr_reader :disabled_handlers

        def remove_propagation_handler(id)
            disabled_handlers.delete_if { |p| p.id == id }
            super
            nil
        end

        class JoinAllWaitingWorkTimeout < RuntimeError
            attr_reader :waiting_work
            def initialize(waiting_work)
                @waiting_work = waiting_work
            end

            def pretty_print(pp)
                pp.text "timed out in #join_all_waiting_work, #{waiting_work.size} promises waiting"
                waiting_work.each do |w|
                    pp.breakable
                    pp.nest(2) do
                        w.pretty_print(pp)
                    end
                end
            end
        end

        # Waits for all obligations in {#waiting_work} to finish
        def join_all_waiting_work(timeout: nil)
            deadline = if timeout
                           Time.now + timeout
                       end

            finished = Array.new
            while waiting_work.any? { |w| !w.unscheduled? }
                process_events_synchronous do
                    finished.concat(process_waiting_work)
                    blocks = Array.new
                    while !once_blocks.empty?
                        blocks << once_blocks.pop.last
                    end
                    call_poll_blocks(blocks)
                end
                Thread.pass
                if deadline && (Time.now > deadline)
                    raise JoinAllWaitingWorkTimeout.new(waiting_work)
                end
            end
            finished
        end

        # The scheduler is the object which handles non-generic parts of the
        # propagation cycle.  For now, its #initial_events method is called at
        # the beginning of each propagation cycle and can call or emit a set of
        # events.
        #
        # See Schedulers::Basic
        attr_reader :scheduler

        def scheduler=(scheduler)
            if !scheduler
                raise ArgumentError, "cannot set the scheduler to nil. You can disable the current scheduler with .enabled = false instead, or set it to Schedulers::Null.new"
            end
            @scheduler = scheduler
        end

        # True if we are currently in the propagation stage
        def gathering?; !!@propagation end

        attr_predicate :allow_propagation

        # The set of source events for the current propagation action. This is a
        # mix of EventGenerator and Event objects.
        attr_reader :propagation_sources
        # The set of events extracted from #sources
        def propagation_source_events
            result = Set.new
            for ev in @propagation_sources
                if ev.respond_to?(:generator)
                    result << ev
                end
            end
            result
        end

        # The set of generators extracted from #sources
        def propagation_source_generators
            result = Set.new
            for ev in @propagation_sources
                result << if ev.respond_to?(:generator)
                              ev.generator
                          else
                              ev
                          end
            end
            result
        end

        # The set of pending delayed events. This is an array of the form
        #
        #   [[time, is_forward, source, target, context], ...]
        #
        # See #add_event_delay for more information
        attr_reader :delayed_events

        # Adds a propagation step to be performed when the current time is
        # greater than +time+. The propagation step is a signal if +is_forward+
        # is false and a forward otherwise.
        #
        # This method should not be called directly. Use #add_event_propagation
        # with the appropriate +timespec+ argument.
        #
        # See also #delayed_events and #execute_delayed_events
        def add_event_delay(time, is_forward, source, target, context)
            delayed_events << [time, is_forward, source, target, context]
        end

        # Adds the events in +delayed_events+ whose time has passed into the
        # propagation. This must be called in propagation context.
        #
        # See #add_event_delay and #delayed_events
        def execute_delayed_events
            reftime = Time.now
            delayed_events.delete_if do |time, forward, source, signalled, context|
                if time <= reftime
                    add_event_propagation(forward, [source], signalled, context, nil)
                    true
                end
            end
        end

        # Called by EventGenerator when an event became unreachable
        def unreachable_event(event)
            delayed_events.delete_if { |_, _, _, signalled, _| signalled == event }
        end

        # Called by #plan when an event has been finalized
        def finalized_event(event)
            if @propagation
                @propagation.delete(event)
            end
            event.unreachable!("finalized", plan)
            # since the event is already finalized, 
        end

        # Returns true if some events are queued
        def has_queued_events?
            !@propagation.empty?
        end

        # Sets up a propagation context, yielding the block in it. During this
        # propagation stage, all calls to #emit and #call are stored in an
        # internal hash of the form:
        #   target => [forward_sources, signal_sources]
        #
        # where the two +_sources+ are arrays of the form 
        #   [[source, context], ...]
        #
        # The method returns the resulting hash. Use #gathering? to know if the
        # current engine is in a propagation context, and #add_event_propagation
        # to add a new entry to this set.
        def gather_propagation(initial_set = Hash.new)
            raise InternalError, "nested call to #gather_propagation" if gathering?

            old_allow_propagation, @allow_propagation = @allow_propagation, true

            # The ensure clause must NOT apply to the recursive check above.
            # Otherwise, we end up resetting @propagation_exceptions to nil,
            # which wreaks havoc
            begin
                @propagation = initial_set
                @propagation_sources = nil
                @propagation_step_id = 0

                before = @propagation
                propagation_context([]) do
                    yield
                end

                result, @propagation = @propagation, nil
                return result
            ensure
                @propagation = nil
                @allow_propagation = old_allow_propagation
            end
        end

        # Returns true if there is an error queued that originates from +origin+
        def has_error_from?(origin)
            if @propagation_exceptions
                @propagation_exceptions.any? do |error|
                    error.originates_from?(origin)
                end
            end
        end

        # Register a LocalizedError for future propagation
        #
        # This method must be called in a error-gathering context (i.e.
        # {#gather_error}.
        #
        # @param [#to_execution_exception] e the exception
        # @raise [NotPropagationContext] raised if called outside
        #   {#gather_error}
        def add_error(e)
            plan_exception = e.to_execution_exception
            if @additional_errors
                # We are currently propagating exceptions. Gather new ones in
                # @additional_errors
                @additional_errors << e
            elsif @propagation_exceptions
                @propagation_exceptions << plan_exception
            else
                raise NotPropagationContext, "#add_error called outside an error-gathering context (#add_error)"
            end
        end

        # Yields to the block and registers any raised exception using
        # {#add_framework_error}
        #
        # If the method is called within an exception-gathering context (either
        # {#process_events} or {#gather_framework_errors} itself), nothing else
        # is done. Otherwise, {#process_pending_application_exceptions} is
        # called to re-raise any caught exception
        def gather_framework_errors(source, raise_caught_exceptions: true)
            if @application_exceptions
                recursive_error_gathering_context = true
            else
                @application_exceptions = []
            end

            yield

            if !recursive_error_gathering_context && !raise_caught_exceptions
                clear_application_exceptions
            end
        rescue Exception => e
            add_framework_error(e, source)
            if !recursive_error_gathering_context && !raise_caught_exceptions
                clear_application_exceptions
            end
        ensure
            if !recursive_error_gathering_context && raise_caught_exceptions
                process_pending_application_exceptions
            end
        end

        def process_pending_application_exceptions(application_errors = clear_application_exceptions)
            # We don't aggregate exceptions, so report them all and raise one
            application_errors.each do |error, source|
                ExecutionEngine.error "Application error in #{source}"
                Roby.format_exception(error).each do |line|
                    Roby.warn line
                end
            end

            error, source = application_errors.find do |error, _|
                Roby.app.abort_on_application_exception? || error.kind_of?(SignalException)
            end
            if error
                raise error, "in #{source}: #{error.message}", error.backtrace
            end
        end

        # Registers the given error and a description of its source in the list
        # of application/framework errors
        #
        # It must be called within an exception-gathering context, that is
        # either within {#process_events}, or within {#gather_framework_errors}
        #
        # These errors will terminate the event loop
        #
        # @param [Exception] error
        # @param [Object] source
        def add_framework_error(error, source)
            if @application_exceptions
                @application_exceptions << [error, source]
            else
                raise NotPropagationContext, "#add_framework_error called outside an exception-gathering context"
            end
        end

        # Sets the source_event and source_generator variables according
        # to +source+. +source+ is the +from+ argument of #add_event_propagation
        def propagation_context(sources)
            current_sources = @propagation_sources
            raise InternalError, "not in a gathering context in #propagation_context" unless gathering?

            @propagation_sources = sources
            yield
        ensure
            @propagation_sources = current_sources
        end

        def has_propagation_for?(target)
            @propagation && @propagation.has_key?(target)
        end

        def merge_propagation_steps(steps1, steps2)
            steps1.merge(steps2) do |target, sets1, sets2|
                result = [nil, nil]
                if sets1[0] || sets2[0]
                    result[0] = (sets1[0] || []).concat(sets2[0] || [])
                end
                if sets1[1] || sets2[1]
                    result[1] = (sets1[1] || []).concat(sets2[1] || [])
                end
            end
        end

        # Queue a signal to be propagated
        def queue_signal(sources, target, context, timespec)
            add_event_propagation(false, sources, target, context, timespec)
        end

        # Queue a forwarding to be propagated
        def queue_forward(sources, target, context, timespec)
            add_event_propagation(true, sources, target, context, timespec)
        end

        PENDING_PROPAGATION_FORWARD = 1
        PENDING_PROPAGATION_SIGNAL  = 2

        # Adds a propagation to the next propagation step: it registers a
        # propagation step to be performed between +source+ and +target+ with
        # the given +context+. If +is_forward+ is true, the propagation will be
        # a forwarding, otherwise it is a signal.
        #
        # If +timespec+ is not nil, it defines a delay to be applied before
        # calling the target event.
        #
        # See #gather_propagation
        def add_event_propagation(is_forward, sources, target, context, timespec)
            if target.plan != plan
                raise Roby::EventNotExecutable.new(target), "#{target} not in executed plan"
            end

            @propagation_step_id += 1
            target_info = (@propagation[target] ||= [@propagation_step_id, [], []])
            step = target_info[is_forward ? PENDING_PROPAGATION_FORWARD : PENDING_PROPAGATION_SIGNAL]
            if sources.empty?
                step << nil << context << timespec
            else
                sources.each do |ev|
                    step << ev << context << timespec
                end
            end
        end

        # Whether a forward matching this signature is currently pending
        def has_pending_forward?(from, to, expected_context)
            if pending = @propagation[to]
                pending[PENDING_PROPAGATION_FORWARD].each_slice(3).any? do |event, context, timespec|
                    (from === event.generator) && (expected_context === context)
                end
            end
        end

        # Whether a signal matching this signature is currently pending
        def has_pending_signal?(from, to, expected_context)
            if pending = @propagation[to]
                pending[PENDING_PROPAGATION_SIGNAL].each_slice(3).any? do |event, context, timespec|
                    (from === event.generator) && (expected_context === context)
                end
            end
        end

        # Helper that calls the propagation handlers in +propagation_handlers+
        # (which are expected to be instances of PollBlockDefinition) and
        # handles the errors according of each handler's policy
        def call_poll_blocks(blocks, late = false)
            blocks.delete_if do |handler|
                if handler.disabled? || (handler.late? ^ late)
                    next
                end

                log_timepoint_group handler.description do
                    if !handler.call(self, plan)
                        handler.disabled = true
                    end
                end
                handler.once?
            end
        end

        # Dispatch {#once_blocks} to the other handler sets for further
        # processing
        def process_once_blocks
            while !once_blocks.empty?
                type, block = once_blocks.pop
                if type == :external_events
                    external_events_handlers << block
                else
                    propagation_handlers << block
                end
            end
        end

        # Gather the events that come out of this plan manager
        def gather_external_events
            process_once_blocks
            gather_framework_errors('delayed events')     { execute_delayed_events }
            call_poll_blocks(self.class.external_events_handlers)
            call_poll_blocks(self.external_events_handlers)
        end

        def call_propagation_handlers
            process_once_blocks
            if scheduler.enabled?
                gather_framework_errors('scheduler') do
                    scheduler.initial_events
                    log_timepoint 'scheduler'
                end
            end
            call_poll_blocks(self.class.propagation_handlers, false)
            call_poll_blocks(self.propagation_handlers, false)

            if !has_queued_events?
                call_poll_blocks(self.class.propagation_handlers, true)
                call_poll_blocks(self.propagation_handlers, true)
            end
        end

        # Whether we're in a #gather_errors context
        def gathering_errors?
            !!@propagation_exceptions
        end

        # Executes the given block while gathering errors, and returns the
        # errors that have been declared with #add_error
        #
        # @return [Array<ExecutionException>]
	def gather_errors
            if @propagation_exceptions
                raise InternalError, "recursive call to #gather_errors"
            end

            # The ensure clause must NOT apply to the recursive check above.
            # Otherwise, we end up resetting @propagation_exceptions to nil,
            # which wreaks havoc
            begin
                @propagation_exceptions = []
                yield
                @propagation_exceptions

            ensure
                @propagation_exceptions = nil
            end
	end

        # Calls its block in a #gather_propagation context and propagate events
        # that have been called and/or emitted by the block
        #
        # If a block is given, it is called with the initial set of events: the
        # events we should consider as already emitted in the following propagation.
        # +seeds+ si a list of procs which should be called to initiate the propagation
        # (i.e. build an initial set of events)
        def event_propagation_phase(initial_events)
            @propagation_id = (@propagation_id += 1)

	    gather_errors do
                next_steps = initial_events
                while !next_steps.empty?
                    while !next_steps.empty?
                        next_steps = event_propagation_step(next_steps)
                    end        
                    next_steps = gather_propagation { call_propagation_handlers }
                end
	    end
        end
        
        # Compute errors in plan and handle the results
        def error_handling_phase(events_errors)
            # Do the exception handling phase
            errors = compute_errors(events_errors)
            notify_about_error_handling_results(errors)

            # nonfatal errors are only notified. Fatal errors (kill_tasks) are
            # handled in the propagation loop during garbage collection. Only
            # the free events errors have to be handled here.
            errors.free_events_errors.each do |exception, generators|
                generators.each { |g| g.unreachable!(exception.exception) }
            end
            return errors
        end

        # Compute the set of unhandled fatal exceptions
        def compute_kill_tasks_for_unhandled_fatal_errors(fatal_errors)
            kill_tasks = fatal_errors.inject(Set.new) do |tasks, (exception, affected_tasks)|
                tasks | (affected_tasks || exception.trace).to_set
            end
            # Tasks might have been finalized during exception handling, filter
            # those out
            kill_tasks.find_all(&:plan)
        end

        # Issue the warning message and log notifications related to tasks being
        # killed because of unhandled fatal exceptions
        def notify_about_error_handling_results(errors)
            kill_tasks, fatal_errors, nonfatal_errors, free_events_errors =
                errors.kill_tasks, errors.fatal_errors, errors.nonfatal_errors, errors.free_events_errors

            if !nonfatal_errors.empty?
                warn "#{nonfatal_errors.size} unhandled non-fatal exceptions"
                nonfatal_errors.each do |exception, tasks|
                    notify_exception(EXCEPTION_NONFATAL, exception, tasks)
                end
            end

            if !free_events_errors.empty?
                warn "#{free_events_errors.size} free event exceptions"
                free_events_errors.each do |exception, events|
                    notify_exception(EXCEPTION_FREE_EVENT, exception, events)
                end
            end

            if !kill_tasks.empty?
                warn "#{fatal_errors.size} unhandled fatal exceptions, involving #{kill_tasks.size} tasks that will be forcefully killed"
                fatal_errors.each do |exception, tasks|
                    notify_exception(EXCEPTION_FATAL, exception, tasks)
                end
                kill_tasks.each do |task|
                    log_pp :warn, task
                end
            end
        end

        # Validates +timespec+ as a delay specification. A valid delay
        # specification is either +nil+ or a hash, in which case two forms are
        # possible:
        #
        #   at: absolute_time
        #   delay: number
        #
        def self.validate_timespec(timespec)
            if timespec
                timespec = validate_options timespec, [:delay, :at]
            end
        end

        # Returns a Time object which represents the absolute point in time
        # referenced by +timespec+ in the context of delaying a propagation
        # between +source+ and +target+.
        #
        # See validate_timespec for more information
        def self.make_delay(timeref, source, target, timespec)
            if delay = timespec[:delay] then timeref + delay
            elsif at = timespec[:at] then at
            else
                raise ArgumentError, "invalid timespec #{timespec}"
            end
        end

        # The topological ordering of events w.r.t. the Precedence relation.
        # This gets updated on-demand when the event relations change.
        attr_reader :event_ordering
        # The event => index hash which give the propagation priority for each
        # event
        attr_reader :event_priorities

        # call-seq:
        #   next_event(pending) => event, propagation_info
        #
        # Determines the event in +current_step+ which should be signalled now.
        # Removes it from the set and returns the event and the associated
        # propagation information.
        #
        # See #gather_propagation for the format of the returned # +propagation_info+
        def next_event(pending)
            # this variable is 2 if selected_event is being forwarded, 1 if it
            # is both forwarded and signalled and 0 if it is only signalled
            priority, step_id, selected_event = nil
            for propagation_step in pending
                target_event = propagation_step[0]
                target_step_id, forwards, signals = *propagation_step[1]
                target_priority = if forwards.empty? && signals.empty? then 2
                                  elsif forwards.empty? then 0
                                  else 1
                                  end

                do_select = if selected_event
                                if precedence_graph.reachable?(selected_event, target_event)
                                    false
                                elsif precedence_graph.reachable?(target_event, selected_event)
                                    true
                                elsif priority < target_priority
                                    true
                                elsif priority == target_priority
                                    # If they are of the same priority, handle
                                    # earlier events first
                                    step_id > target_step_id
                                else
                                    false
                                end
                            else
                                true
                            end

                if do_select
                    selected_event = target_event
                    priority       = target_priority
                    step_id        = target_step_id
                end
            end
            [selected_event, *pending.delete(selected_event)]
        end

        # call-seq:
        #   prepare_propagation(target, is_forward, info) => source_events, source_generators, context
        #   prepare_propagation(target, is_forward, info) => nil
        #
        # Parses the propagation information +info+ in the context of a
        # signalling if +is_forward+ is true and a forwarding otherwise.
        # +target+ is the target event.
        #
        # The method adds the appropriate delayed events using #add_event_delay,
        # and returns either nil if no propagation is to be performed, or the
        # propagation source events, generators and context.
        #
        # The format of +info+ is the same as the hash values described in
        # #gather_propagation.
        def prepare_propagation(target, is_forward, info)
            timeref = Time.now

            source_events, source_generators, context = Set.new, Set.new, []

            delayed = true
            info.each_slice(3) do |src, ctxt, time|
                if time && (delay = ExecutionEngine.make_delay(timeref, src, target, time))
                    add_event_delay(delay, is_forward, src, target, ctxt)
                    next
                end

                delayed = false

                # Merge identical signals. Needed because two different event handlers
                # can both call #emit, and two signals are set up
                if src
                    if src.respond_to?(:generator)
                        source_events << src 
                        source_generators << src.generator
                    else
                        source_generators << src
                    end
                end
                if ctxt
                    context.concat ctxt
                end
            end

            unless delayed
                [source_events, source_generators, context]
            end
        end
       

        # Propagate one step
        #
        # +current_step+ describes all pending emissions and calls.
        # 
        # This method calls ExecutionEngine.next_event to get the description of the
        # next event to call. If there are signals going to this event, they are
        # processed and the forwardings will be treated in the next step.
        #
        # The method returns the next set of pending emissions and calls, adding
        # the forwardings and signals that the propagation of the considered event
        # have added.
        def event_propagation_step(current_step)
            signalled, step_id, forward_info, call_info = next_event(current_step)

            next_step = nil
            if !call_info.empty?
                source_events, source_generators, context =
                    prepare_propagation(signalled, false, call_info)
                if source_events
                    log(:generator_propagate_events, false, source_events, signalled)

                    if signalled.self_owned?
                        next_step = gather_propagation(current_step) do
                            propagation_context(source_events | source_generators) do
                                begin
                                    signalled.call_without_propagation(context) 
                                rescue Roby::LocalizedError => e
                                    if signalled.command_emitted?
                                        add_error(e)
                                    else
                                        signalled.emit_failed(e)
                                    end
                                rescue Exception => e
                                    if signalled.command_emitted?
                                        add_error(Roby::CommandFailed.new(e, signalled))
                                    else
                                        signalled.emit_failed(Roby::CommandFailed.new(e, signalled))
                                    end
                                end
                            end
                        end
                    end
                end

                if forward_info
                    next_step ||= Hash.new
                    target_info = (next_step[signalled] ||= [@propagation_step_id += 1, [], []])
                    target_info[PENDING_PROPAGATION_FORWARD].concat(forward_info)
                end

            elsif !forward_info.empty?
                source_events, source_generators, context =
                    prepare_propagation(signalled, true, forward_info)
                if source_events
                    log(:generator_propagate_events, true, source_events, signalled)

                    # If the destination event is not owned, but if the peer is not
                    # connected, the event is our responsibility now.
                    if signalled.self_owned? || !signalled.owners.any? { |peer| peer != plan.local_owner && peer.connected? }
                        next_step = gather_propagation(current_step) do
                            propagation_context(source_events | source_generators) do
                                begin
                                    if event = signalled.emit_without_propagation(context)
                                        emitted_events << event
                                    end
                                rescue Roby::LocalizedError => e
				    Roby.warn "Internal Error: #emit_without_propagation emitted a LocalizedError exception. This is unsupported and will become a fatal error in the future. You should usually replace raise with engine.add_error"
                                    Roby.display_exception(Roby.logger.io(:warn), e, false)
                                    add_error(e)
                                rescue Exception => e
				    Roby.warn "Internal Error: #emit_without_propagation emitted an exception. This is unsupported and will become a fatal error in the future. You should create a proper localized error and replace raise with engine.add_error"
                                    Roby.display_exception(Roby.logger.io(:warn), e, false)
                                    add_error(Roby::EmissionFailed.new(e, signalled))
                                end
                            end
                        end
                    end
                end
            end

            current_step.merge!(next_step) if next_step
            current_step
        end

        # Graph visitor that propagates exceptions in the dependency graph
        class ExceptionPropagationVisitor < Relations::ForkMergeVisitor
            attr_reader :exception_handler
            attr_reader :handled_exceptions
            attr_reader :unhandled_exceptions

            def initialize(graph, object, origin, origin_neighbours = graph.out_neighbours(origin), &exception_handler)
                super(graph, object, origin, origin_neighbours)
                @exception_handler = exception_handler
                @handled_exceptions = Array.new
                @unhandled_exceptions = Array.new
            end

            def handle_examine_vertex(u)
                e = vertex_to_object[u]
                return if e.handled?
                if u != origin
                    e.trace << u
                end
                if e.handled = exception_handler[e, u]
                    handled_exceptions << e
                elsif out_degree[u] == 0
                    unhandled_exceptions << e
                end
            end

            def follow_edge?(u, v)
                if !vertex_to_object[u].handled?
                    super
                end
            end
        end

        # The core exception propagation algorithm
        #
        # @param [Array<(ExecutionException,Array<Task>)>] exceptions the set of
        #   exceptions to propagate, as well as the parents that towards which
        #   we should propagate them (if empty, all parents)
        #
        # @yieldparam [ExecutionException] exception the exception that is being
        #   propagated
        # @yieldparam [Task,Plan] handling_object the object we want to test
        #   whether it handles the exception or not
        # @yieldreturn [Boolean] true if the exception is handled, false
        #   otherwise
        #
        # @return [Array<(ExecutionException,Array<Task>)>] the set of unhandled
        #   exceptions, as a mapping from an exception description to the set of
        #   tasks that are affected by it
        def propagate_exception_in_plan(exceptions)
            propagation_graph = dependency_graph.reverse

            # Propagate the exceptions in the hierarchy

            unhandled = Array.new
            exceptions_handled_by_tasks = Hash.new
            exceptions.each do |exception, parents|
                origin = exception.origin
                if parents
                    filtered_parents = parents.find_all { |t| t.depends_on?(origin) }
                    if filtered_parents != parents
                        warn "some parents specified for #{exception.exception}(#{exception.exception.class}) are actually not parents of #{origin}, they got filtered out"
                        (parents - filtered_parents).each do |task|
                            warn "  #{task}"
                        end
                    end
                    parents = filtered_parents
                end
                if !parents || parents.empty?
                    parents = propagation_graph.out_neighbours(origin)
                end

                debug do
                    debug "propagating exception "
                    log_pp :debug, exception
                    if !parents.empty?
                        debug "  constrained to parents"
                        log_nest(2) do
                            parents.each do |p|
                                log_pp :debug, p
                            end
                        end
                    end
                    break
                end

                visitor = ExceptionPropagationVisitor.new(propagation_graph, exception, origin, parents) do |e, task|
                    yield(e, task)
                end
                visitor.visit
                unhandled.concat(visitor.unhandled_exceptions.to_a)
                exceptions_handled_by_tasks[exception.exception] = visitor.handled_exceptions
            end

            exceptions_handled_by_plan = Hash.new
            unhandled = unhandled.find_all do |e|
                if e.handled = yield(e, plan)
                    exceptions_handled_by_plan[e.exception] = e
                    false
                else
                    true
                end
            end

            # Finally, compute the set of tasks that are affected by the
            # unhandled exceptions
            unhandled = unhandled.map do |e|
                affected_tasks = e.trace.dup
                exceptions_handled_by_tasks[e.exception].each do |handled_e|
                    affected_tasks -= handled_e.trace
                end
                [e, affected_tasks]
            end

            exceptions_handled_by = Array.new
            exceptions_handled_by_tasks.each do |actual_exception, exceptions|
                handled_by = exceptions.map(&:task)
                if plan_handled_e = exceptions_handled_by_plan[actual_exception]
                    handled_by << plan
                    e = exceptions.inject(plan_handled_e) { |a, b| a.merge(b) }
                elsif exceptions.empty?
                    next
                else
                    e = exceptions.inject { |a, b| a.merge(b) }
                end
                exceptions_handled_by << [e, handled_by]
            end

            debug do
                debug "#{unhandled.size} unhandled exceptions remain"
                log_nest(2) do
                    unhandled.each do |e, affected_tasks|
                        log_pp :debug, e
                        debug "Affects #{affected_tasks.size} tasks"
                        log_nest(2) do
                            affected_tasks.each do |t|
                                log_pp :debug, t
                            end
                        end
                    end
                end
                break
            end
            return unhandled, exceptions_handled_by
        end

        # Propagation exception phase, checking if tasks and/or the main plan
        # are handling the exceptions
        #
        # @param [Array<(ExecutionException,Array<Task>)>] exceptions the set of
        #   exceptions to propagate, as well as the parents that towards which
        #   we should propagate them (if empty, all parents)
        # @return (see propagate_exception_in_plan)
        def propagate_exceptions(exceptions)
            # Remove all exception that are not associated with a task
            exceptions, free_events_exceptions = exceptions.partition do |e, _|
                e.origin
            end
            # Normalize the free events exceptions
            free_events_exceptions = free_events_exceptions.inject(Hash.new) do |h, (e, _)|
                h[e] = Set[e.exception.failed_generator]
                h
            end

            debug "Filtering inhibited exceptions"
            exceptions = log_nest(2) do
                non_inhibited = remove_inhibited_exceptions(exceptions)
                exceptions.find_all do |exception, _|
                    exception.reset_trace
                    non_inhibited.any? { |e, _| e.exception == exception.exception }
                end
            end

            debug "Propagating #{exceptions.size} non-inhibited exceptions"
            unhandled = log_nest(2) do
                # Note that the first half of the method filtered the free
                # events exceptions out of 'exceptions'
                unhandled, handled = propagate_exception_in_plan(exceptions) do |e, object|
                    object.handle_exception(e)
                end
                handled.each do |exception, handlers|
                    notify_exception(EXCEPTION_HANDLED, exception, handlers.to_set)
                end
                unhandled
            end

            return unhandled, free_events_exceptions
        end

        # Process the given exceptions to remove the ones that are currently
        # filtered by the plan repairs
        #
        # The returned exceptions are propagated, i.e. their #trace method
        # contains all the tasks that are affected by the absence of a handling
        # mechanism
        #
        # @param [(ExecutionException,Array<Roby::Task>)] exceptions pairs of
        #   exceptions as well as the "root tasks", i.e. the parents of
        #   origin.task towards which they should be propagated
        # @return [Array<ExecutionException>] the unhandled exceptions
        def remove_inhibited_exceptions(exceptions)
            unhandled, _ = propagate_exception_in_plan(exceptions) do |e, object|
                if plan.force_gc.include?(object)
                    true
                elsif object.respond_to?(:handles_error?)
                    object.handles_error?(e)
                end
            end
            return unhandled
        end

        # Query whether the given exception is inhibited in this plan
        def inhibited_exception?(exception)
            remove_inhibited_exceptions([exception.to_execution_exception]).empty?
        end

        # Schedules +block+ to be called at the beginning of the next execution
        # cycle, in propagation context.
        #
        # @param [#fail] sync a synchronization object that is used to
        #   communicate between the once block and the calling thread. The main
        #   use of this parameter is to make sure that #fail is called if the
        #   execution engine quits
        # @param (see PropagationHandlerMethods#create_propagation_handler)
        def once(sync: nil, description: 'once block', type: :external_events, **options, &block)
            waiting_work << sync if sync
            once_blocks << create_propagation_handler(description: description, type: type, once: true, **options, &block)
        end

        # Schedules +block+ to be called once after +delay+ seconds passed, in
        # the propagation context
        def delayed(delay, description: 'delayed block', **options, &block)
            handler = PollBlockDefinition.new(description, block, once: true, **options)
            once do
                process_every << [handler, cycle_start, delay]
            end
            handler.id
        end

        # The set of errors which have been generated outside of the plan's
        # control. For now, those errors cause the whole controller to shut
        # down.
        attr_reader :application_exceptions
        def clear_application_exceptions
            if !@application_exceptions
                raise RecursivePropagationContext, "unbalanced call to #clear_application_exceptions"
            end

            result, @application_exceptions = @application_exceptions, nil
            result
        end
        
        # Abort the control loop because of +exceptions+
        def reraise(exceptions)
            if exceptions.size == 1
                e = exceptions.first
                if e.kind_of?(Roby::ExecutionException)
                    e = e.exception
                end
                raise e, e.message, e.backtrace
            else
                raise Aborting.new(exceptions.map(&:exception))
            end
        end

        # Used during exception propagation to inject new errors in the process
        #
        # It shall not be accessed directly. Instead, Plan#add_error should be
        # called
        attr_reader :additional_errors

        # Compute the set of fatal errors in the current execution state
        #
        # @param [Array] events_errors the set of errors gathered during event
        #   propagation
        # @return [ErrorPhaseResult]
        def compute_errors(events_errors)
            # Generate exceptions from task structure
            structure_errors = plan.check_structure
            log_timepoint 'structure_check'

            if @additional_errors
                raise InternalError, "recursive call to #compute_errors"
            end
            @additional_errors = Array.new

            # Propagate the errors. Note that the plan repairs are taken into
            # account in ExecutionEngine.propagate_exceptions directly.  We keep
            # event and structure errors separate since in the first case there
            # is not two-stage handling (all errors that have not been handled
            # are fatal), and in the second case we call #check_structure
            # again to errors that are remaining after the call to the exception
            # handlers
            events_errors, free_events_errors = propagate_exceptions(events_errors)
            propagate_exceptions(structure_errors)

            unhandled_additional_errors = Array.new
            10.times do
                break if additional_errors.empty?
                errors, @additional_errors = additional_errors, Array.new
                unhandled, new_free_events_errors =
                    propagate_exceptions(plan.format_exception_set(Hash.new, errors))
                unhandled_additional_errors.concat(unhandled.to_a)
                free_events_errors.merge!(new_free_events_errors) do |_, a, b|
                    a.merge(b)
                end
            end
            @additional_errors = nil

            log_timepoint 'exception_propagation'

            # Get the remaining problems in the plan structure, and act on it
            errors = remove_inhibited_exceptions(plan.check_structure)
            # Add events_errors and unhandled_additional_errors to fatal_errors.
            # Note that all the objects in fatal_errors now have a proper trace
            errors.concat(events_errors.to_a)
            errors.concat(unhandled_additional_errors.to_a)

            # Partition between fatal and non-fatal errors. Simply log & notify
            # for the nonfatal ones
            fatal_errors, nonfatal_errors = Hash.new, Hash.new
            errors.each do |e, tasks|
                if e.fatal?
                    fatal_errors[e] = tasks.to_set
                else
                    nonfatal_errors[e] = tasks.to_set
                end
            end
            kill_tasks = compute_kill_tasks_for_unhandled_fatal_errors(fatal_errors).to_set

            debug "#{fatal_errors.size} fatal errors found and #{free_events_errors.size} errors involving free events"
            debug "the fatal errors involve #{kill_tasks} non-finalized tasks"
            return ErrorPhaseResult.new(kill_tasks, fatal_errors, nonfatal_errors, free_events_errors)
        ensure
            @additional_errors = nil
        end

        def garbage_collect_synchronous
            tasks_size = nil
            while plan.tasks.size != tasks_size
                if !tasks_size
                    tasks_size = true
                else
                    tasks_size = plan.tasks.size
                end
                process_events_synchronous do
                    garbage_collect([])
                end
            end
        end

        # Whether this EE has asynchronous waiting work waiting to be processed
        def has_waiting_work?
            !waiting_work.empty?
        end

        # Process asynchronous work registered in {#waiting_work} to clear
        # completed work and/or handle errors that were not handled by the async
        # object itself (e.g. a {Promise} without a {Promise#on_error} handler)
        def process_waiting_work
            finished, not_finished = waiting_work.partition do |work|
                work.complete?
            end

            finished.find_all do |work|
                work.rejected? && (work.respond_to?(:has_error_handler?) && !work.has_error_handler?)
            end.each do |work|
                e = work.reason
                e.set_backtrace(e.backtrace + caller)
                add_framework_error(e, work.to_s)
            end

            @waiting_work = not_finished
            finished
        end

        # Gathering of all the errors that happened during an event processing
        # loop and were not handled
        ErrorPhaseResult = Struct.new :kill_tasks, :fatal_errors, :nonfatal_errors, :free_events_errors do
            def initialize(kill_tasks = Set.new,
                           fatal_errors = Hash.new,
                           nonfatal_errors = Hash.new,
                           free_events_errors = Hash.new)

                self.kill_tasks         = kill_tasks.to_set
                self.fatal_errors       = fatal_errors
                self.nonfatal_errors    = nonfatal_errors
                self.free_events_errors = free_events_errors
            end

            def merge(results)
                self.kill_tasks.merge(results.kill_tasks)
                self.fatal_errors.merge!(results.fatal_errors) do |_, a, b|
                    a.merge(b)
                end
                self.nonfatal_errors.merge!(results.nonfatal_errors) do |_, a, b|
                    a.merge(b)
                end
                self.free_events_errors.merge!(results.free_events_errors) do |_, a, b|
                    a.merge(b)
                end
            end

            # Return the exception objects registered in this result object
            def exceptions
                fatal_errors.keys + nonfatal_errors.keys + free_events_errors.keys
            end
        end

        # The methods that setup propagation context in ExecutionEngine must not
        # be called recursively.
        #
        # This exception is thrown if such a recursive call is detected
        class RecursivePropagationContext < RuntimeError; end

        # Some methods require to be called within a gather_* block. This
        # exception is raised when they're called outside of it
        class NotPropagationContext < RuntimeError; end
        
        # The inside part of the event loop
        #
        # It gathers initial events and errors and propagate them
        #
        # @return [ErrorPhaseResult] the set of errors that have been detected
        #   and propagated
        # @raise RecursivePropagationContext if called recursively
        def process_events(garbage_collect_pass: true)
            if @application_exceptions
                raise RecursivePropagationContext, "recursive call to process_events"
            end
            passed_recursive_check = true # to avoid having a almost-method-global ensure block
            @application_exceptions = []
            @emitted_events = Array.new

            # Gather new events and propagate them
	    events_errors = nil
            next_steps = gather_propagation do
	        events_errors = gather_errors do
                    if !quitting? || !garbage_collect([])
                        process_waiting_work
                        log_timepoint 'workers'
                        gather_external_events
                        log_timepoint 'external_events'
                        call_propagation_handlers
                        log_timepoint 'propagation_handlers'
                    end
	        end
            end

            all_errors = propagate_events_and_errors(next_steps, events_errors, garbage_collect_pass: garbage_collect_pass)
            if Roby.app.abort_on_exception? && !all_errors.fatal_errors.empty?
                reraise(all_errors.fatal_errors.keys)
            end
            all_errors

        ensure
            if passed_recursive_check
                process_pending_application_exceptions
            end
        end

        # Tests are using a special mode for propagation, in which everything is
        # resolved when #emit or #call is called, including error handling. This
        # mode is implemented using this method
        #
        # When errors occur in this mode, the exceptions are raised directly.
        # This is useful in tests as, this way, we are sure that the exception
        # will not get overlooked
        #
        # If multiple errors are raised in a single call (this is possible due
        # to Roby's error handling mechanisms), the method will raise
        # SynchronousEventProcessingMultipleErrors to wrap all the exceptions
        # into one.
        def process_events_synchronous(seeds = Hash.new, initial_errors = Array.new, enable_scheduler: false, raise_errors: true)
            if @application_exceptions
                raise RecursivePropagationContext, "recursive call to process_events"
            end
            passed_recursive_check = true # to avoid having a almost-method-global ensure block
            @application_exceptions = []

            # Save early for the benefit of the 'ensure' block
            current_scheduler_enabled = scheduler.enabled?

            if (!seeds.empty? || !initial_errors.empty?) && block_given?
                raise ArgumentError, "cannot provide both seeds/inital errors and a block"
            elsif block_given?
                seeds = gather_propagation do
                    initial_errors = gather_errors do
                        yield
                    end
                end
            end

            scheduler.enabled = enable_scheduler

            all_errors = propagate_events_and_errors(seeds, initial_errors, garbage_collect_pass: false)
            if !all_errors.kill_tasks.empty?
                gc_initial_errors = nil
                gc_seeds = gather_propagation do
                    gc_initial_errors = gather_errors do
                        garbage_collect(all_errors.kill_tasks)
                    end
                end
                gc_errors = propagate_events_and_errors(gc_seeds, gc_initial_errors, garbage_collect_pass: false)
                all_errors.merge(gc_errors)
            end

            if raise_errors
                all_errors = all_errors.exceptions
                if all_errors.size == 1
                    raise all_errors.first
                elsif !all_errors.empty?
                    raise SynchronousEventProcessingMultipleErrors.new(all_errors.map(&:exception))
                end
            else
                all_errors
            end

        rescue SynchronousEventProcessingMultipleErrors => e
            raise SynchronousEventProcessingMultipleErrors.new(e.errors + clear_application_exceptions)

        rescue Exception => e
            application_exceptions = clear_application_exceptions
            if !application_exceptions.empty?
                raise SynchronousEventProcessingMultipleErrors.new(application_exceptions + [e])
            else raise e
            end

        ensure
            if @application_exceptions
                process_pending_application_exceptions
            end
            scheduler.enabled = current_scheduler_enabled
        end


        # Propagate an initial set of event propagations and errors
        #
        # @param [Array] next_steps the next propagations, as returned by
        #   {#gather_propagation}
        # @param [Array] initial_errors a set of errors that should be
        #   propagated
        # @param [Boolean] garbage_collect_pass whether the garbage collection
        #   pass should be performed or not. It is used in the tests' codepath
        #   for {EventGenerator#call} and {EventGenerator#emit}.
        # @return [ErrorPhaseResult] the set of errors that have been detected
        #   and propagated
        def propagate_events_and_errors(next_steps, initial_errors, garbage_collect_pass: true)
            all_errors = ErrorPhaseResult.new
            first_pass = true
            events_errors = initial_errors.dup
            while first_pass || !next_steps.empty? || !events_errors.empty?
                first_pass = false
                log_timepoint_group 'event_propagation_phase' do
                    events_errors.concat(event_propagation_phase(next_steps))
                end

                next_steps = gather_propagation do
                    error_phase_results =
                        log_timepoint_group 'error_handling_phase' do
                            error_handling_phase(events_errors)
                        end

                    all_errors.merge(error_phase_results)
                    events_errors = gather_errors do
                        if garbage_collect_pass
                            garbage_collect(error_phase_results.kill_tasks)
                        else []
                        end
                    end
                    log_timepoint 'garbage_collect'
                end
            end
            all_errors
        end

        def unmark_finished_missions_and_permanent_tasks
            to_unmark = plan.task_index.by_predicate[:finished?] | plan.task_index.by_predicate[:failed?]

            finished_missions = (plan.mission_tasks & to_unmark)
	    # Remove all missions that are finished
	    for finished_mission in finished_missions
                if !finished_mission.being_repaired?
                    plan.unmark_mission_task(finished_mission)
                end
	    end
            finished_permanent = (plan.permanent_tasks & to_unmark)
	    for finished_permanent in (plan.permanent_tasks & to_unmark)
                if !finished_permanent.being_repaired?
                    plan.unmark_permanent_task(finished_permanent)
                end
	    end
        end
        
        # Kills and removes all unneeded tasks. +force_on+ is a set of task
        # whose garbage-collection must be performed, even though those tasks
        # are actually useful for the system. This is used to properly kill
        # tasks for which errors have been detected.
        #
        # @return [Boolean] true if events have been called (thus requiring
        #   some propagation) and false otherwise
        def garbage_collect(force_on = nil)
            if force_on && !force_on.empty?
                ExecutionEngine.info "GC: adding #{force_on.size} tasks in the force_gc set"
                mismatching_plan = force_on.find_all do |t|
                    if t.plan == self.plan
                        plan.force_gc << t
                        false
                    else
                        true
                    end
                end
                if !mismatching_plan.empty?
                    raise ArgumentError, "#{mismatching_plan.map { |t| "#{t}(plan=#{t.plan})" }.join(", ")} have been given to #{self}.garbage_collect, but they are not tasks in #{plan}"
                end
            end

            unmark_finished_missions_and_permanent_tasks

            # The set of tasks for which we queued stop! at this cycle
            # #finishing? is false until the next event propagation cycle
            finishing = Set.new
            did_something = true
            while did_something
                did_something = false

                tasks = plan.unneeded_tasks | plan.force_gc
                local_tasks  = plan.local_tasks & tasks
                remote_tasks = tasks - local_tasks

                # Remote tasks are simply removed, regardless of other concerns
                for t in remote_tasks
                    ExecutionEngine.debug { "GC: removing the remote task #{t}" }
                    plan.garbage_task(t)
                end

                break if local_tasks.empty?

                debug do
                    debug "#{local_tasks.size} tasks are unneeded in this plan"
                    local_tasks.each do |t|
                        debug "  #{t} mission=#{plan.mission_task?(t)} permanent=#{plan.permanent_task?(t)}"
                    end
                    break
                end

                if local_tasks.all? { |t| t.pending? || t.finished? }
                    local_tasks.each do |t|
                        debug { "GC: #{t} is not running, removed" }
                        if plan.garbage_task(t)
                            did_something = true
                        end
                    end
                    break
                end

                # Mark all root local_tasks as garbage.
                roots = nil
                2.times do |i|
                    roots = local_tasks.dup
                    plan.each_task_relation_graph do |g|
                        next if !g.root_relation?
                        roots.delete_if do |t|
                            g.each_in_neighbour(t).any? { |p| !p.finished? }
                        end
                        break if roots.empty?
                    end

                    break if i == 1 || !roots.empty?

                    # There is a cycle somewhere. Try to break it by removing
                    # weak relations within elements of local_tasks
                    debug "cycle found, removing weak relations"

                    plan.each_task_relation_graph do |g|
                        if g.weak?
                            local_tasks.each do |t|
                                g.remove_vertex(t)
                            end
                        end
                    end
                end

                (roots.to_set - finishing - plan.gc_quarantine).each do |local_task|
                    if local_task.pending?
                        info "GC: removing pending task #{local_task}"

                        if plan.garbage_task(local_task)
                            did_something = true
                        end
                    elsif local_task.failed_to_start?
                        info "GC: removing task that failed to start #{local_task}"
                        if plan.garbage_task(local_task)
                            did_something = true
                        end
                    elsif local_task.starting?
                        # wait for task to be started before killing it
                        debug { "GC: #{local_task} is starting" }
                    elsif local_task.finished?
                        debug { "GC: #{local_task} is not running, removed" }
                        if plan.garbage_task(local_task)
                            did_something = true
                        end
                    elsif !local_task.finishing?
                        if local_task.event(:stop).controlable?
                            debug { "GC: queueing #{local_task}/stop" }
                            if !local_task.respond_to?(:stop!)
                                fatal "something fishy: #{local_task}/stop is controlable but there is no #stop! method"
                                plan.quarantine(local_task)
                            else
                                finishing << local_task
                            end
                        else
                            warn "GC: ignored #{local_task}, it cannot be stopped"
                            # We don't use Plan#quarantine as it is normal that
                            # this task does not get GCed
                            plan.gc_quarantine << local_task
                        end
                    elsif local_task.finishing?
                        debug do
			    debug "GC: waiting for #{local_task} to finish"
			    local_task.history.each do |ev|
			        debug "GC:   #{ev}"
			    end
			    break
			end
                    else
                        warn "GC: ignored #{local_task}"
                    end
                end
            end

            finishing.each do |task|
                task.stop!
            end

            plan.unneeded_events.each do |event|
                plan.garbage_event(event)
            end

            !finishing.empty?
        end

	# Do not sleep or call Thread#pass if there is less that
	# this much time left in the cycle
	SLEEP_MIN_TIME = 0.01

	# The priority of the control thread
	THREAD_PRIORITY = 10

	# Blocks until at least once execution cycle has been done
	def wait_one_cycle
	    current_cycle = execute { cycle_index }
	    while current_cycle == execute { cycle_index }
		raise ExecutionQuitError if !running?
		sleep(cycle_length)
	    end
	end

        # Calls the periodic blocks which should be called
        def self.call_every(plan) # :nodoc:
            engine = plan.execution_engine
            now        = engine.cycle_start
            length     = engine.cycle_length
            engine.process_every.map! do |block, last_call, duration|
                # Check if the nearest timepoint is the beginning of
                # this cycle or of the next cycle
                if !last_call || (duration - (now - last_call)) < length / 2
                    if !block.call(engine, engine.plan)
                        next
                    end

                    last_call = now
                end
                [block, last_call, duration]
            end.compact!
        end

        # A list of threaded objects waiting for the control thread
        #
        # Objects registered here will be notified them by calling {#fail} when
        # it quits. In addition, {#join_all_waiting_work} will wait for all
        # pending jobs to finish.
        #
        # Note that all {Concurrent::Obligation} subclasses fit the bill
        #
        # @return [Array<#fail,#complete?>]
        attr_reader :waiting_work

        # A set of blocks that are called at each cycle end
        attr_reader :at_cycle_end_handlers

        # Adds a block to be called at the end of each execution cycle
        #
        # @return [Object] an object that allows to identify the block so that
        #   it can be removed with {#remove_at_cycle_end}
        #
        # @yieldparam [Plan] plan the plan on which this engine runs
        def at_cycle_end(description: 'at_cycle_end', &block)
            handler = PollBlockDefinition.new(description, block, Hash.new)
            at_cycle_end_handlers << handler
            handler.object_id
        end

        # Removes a handler added by {#at_cycle_end}
        #
        # @param [Object] handler_id the value returned by {#at_cycle_end}
        def remove_at_cycle_end(handler_id)
            at_cycle_end_handlers.delete_if { |h| h.object_id == handler_id }
        end

        # A set of blocks which are called every cycle
        attr_reader :process_every

        # Call +block+ every +duration+ seconds. Note that +duration+ is round
        # up to the cycle size (time between calls is *at least* duration)
        #
        # The returned value is the periodic handler ID. It can be passed to
        # #remove_periodic_handler to undefine it.
        def every(duration, description: 'periodic handler', **options, &block)
            handler = PollBlockDefinition.new(description, block, **options)

            once do
                if handler.call(self, plan)
                    process_every << [handler, cycle_start, duration]
                end
            end
            handler.id
        end

        # Removes a periodic handler defined by #every. +id+ is the value
        # returned by #every.
        def remove_periodic_handler(id)
            execute do
                process_every.delete_if { |spec| spec[0].id == id }
            end
        end

        # The execution thread if there is one running
	attr_accessor :thread
        # True if an execution thread is running
	attr_predicate :running?, true

	# The cycle length in seconds
	attr_reader :cycle_length

	# The starting Time of this cycle
	attr_reader :cycle_start

	# The number of this cycle since the beginning
	attr_reader :cycle_index
        
	# True if the current thread is the execution thread of this engine
	#
	# See #outside_control? for a discussion of the use of #inside_control?
	# and #outside_control? when testing the threading context
	def inside_control?
	    t = thread
	    !t || t == Thread.current
	end

        # True if the current thread is not the execution thread of this
        # engine, or if there is not control thread. When you check the current
        # thread context, always use a negated form. Do not do
	#
	#   if Roby.inside_control?
	#     ERROR
	#   end
	#
	# Do instead
	#
	#   if !Roby.outside_control?
	#     ERROR
	#   end
	#
        # Since the first form will fail if there is no control thread, while
        # the second form will work. Use the first form only if you require
        # that there actually IS a control thread.
	def outside_control?
	    t = thread
	    !t || t != Thread.current
	end

	# Main event loop. Valid options are
	# cycle::   the cycle duration in seconds (default: 0.1)
        def run(cycle: 0.1, thread_priority: THREAD_PRIORITY)
	    if running?
		raise "#run has already been called"
	    end
            self.running = true

	    @quit = 0
            @allow_propagation = false
            @waiting_work = Concurrent::Array.new

            @thread = Thread.current
            original_priority = @thread.priority
            @thread.priority = 0

            @cycle_length = cycle
            event_loop

        ensure
            # reset the options only if we are in the control thread
            @thread.priority = original_priority
            @thread = nil
            waiting_work.each do |w|
                if !w.complete?
                    w.fail ExecutionQuitError
                end
            end
            waiting_work.clear
            finalizers.each { |blk| blk.call rescue nil }
            @quit = 0
            @allow_propagation = true
	end

	attr_reader :last_stop_count # :nodoc:

        # Sets up the plan for clearing: it discards all missions and undefines
        # all permanent tasks and events.
        #
        # Returns nil if the plan is cleared, and the set of remaining tasks
        # otherwise. Note that quaranteened tasks are not counted as remaining,
        # as it is not possible for the execution engine to stop them.
	def clear
            plan.mission_tasks.dup.each { |t| plan.unmark_mission_task(t) }
            plan.permanent_tasks.dup.each { |t| plan.unmark_permanent_task(t) }
            plan.permanent_events.dup.each { |t| plan.unmark_permanent_event(t) }
            plan.force_gc.merge( plan.tasks )

            quaranteened_subplan = plan.compute_useful_tasks(plan.gc_quarantine)
            remaining = plan.tasks - quaranteened_subplan

            if remaining.empty?
                # Have to call #garbage_collect one more to make
                # sure that unneeded events are removed as well
                garbage_collect
                # Done cleaning the tasks, clear the remains
                plan.transactions.each do |trsc|
                    trsc.discard_transaction if trsc.self_owned?
                end
                plan.clear
                emitted_events.clear
                return
            end

            if last_stop_count != remaining.size
                if last_stop_count == 0
                    ExecutionEngine.info "control quitting. Waiting for #{remaining.size} tasks to finish (#{plan.num_tasks} tasks still in plan)"
                    remaining.each do |task|
                        ExecutionEngine.info "  #{task}"
                    end
                else
                    ExecutionEngine.info "waiting for #{remaining.size} tasks to finish (#{plan.num_tasks} tasks still in plan)"
                    remaining.each do |task|
                        ExecutionEngine.info "  #{task}"
                    end
                end
                if plan.gc_quarantine.size != 0
                    ExecutionEngine.info "#{plan.gc_quarantine.size} tasks in quarantine"
                end
                @last_stop_count = remaining.size
            end
            remaining
	end

        # If set to true, Roby will warn if the GC cannot be controlled by Roby
        attr_predicate :gc_warning?, true

        # The main event loop. It returns when the execution engine is asked to
        # quit. In general, this does not need to be called direclty: use #run
        # to start the event loop in a separate thread.
	def event_loop
	    @last_stop_count = 0
	    @cycle_start  = Time.now
	    @cycle_index  = 0

            last_process_times = Process.times
            last_dump_time = plan.event_logger.dump_time

	    loop do
		begin
		    if quitting?
                        if thread
                            thread.priority = 0
                        end
			begin
			    return if forced_exit? || !clear
			rescue Exception => e
			    ExecutionEngine.warn "Execution thread failed to clean up"
                            Roby.format_exception(e).each do |line|
                                ExecutionEngine.warn line
                            end
			    return
			end
		    end

                    log_timepoint_group_start "cycle"

		    while Time.now > cycle_start + cycle_length
			@cycle_start += cycle_length
			@cycle_index += 1
		    end
                    stats = Hash.new
                    stats[:start] = [cycle_start.tv_sec, cycle_start.tv_usec]
                    stats[:actual_start] = Time.now - cycle_start
		    stats[:cycle_index] = cycle_index


                    log_timepoint_group 'process_events' do
                        process_events
                    end

                    remaining_cycle_time = cycle_length - (Time.now - cycle_start)

                    if use_oob_gc?
                        stats[:pre_oob_gc] = GC.stat
                        GC::OOB.run
                    end
		    
		    # Sleep if there is enough time for it
		    if remaining_cycle_time > SLEEP_MIN_TIME
			sleep(remaining_cycle_time) 
		    end
                    log_timepoint 'sleep'

                    cycle_end(stats)

		    # Log cycle statistics
		    process_times = Process.times
                    dump_time = plan.event_logger.dump_time
                    stats[:log_queue_size]   = plan.log_queue_size
		    stats[:plan_task_count]  = plan.num_tasks
		    stats[:plan_event_count] = plan.num_free_events
                    stats[:gc] = GC.stat
                    stats[:utime] = process_times.utime - last_process_times.utime
                    stats[:stime] = process_times.stime - last_process_times.stime
                    stats[:dump_time] = dump_time - last_dump_time
                    stats[:state] = Roby::State
                    stats[:end] = Time.now - cycle_start
                    log(:cycle_end, stats)

                    last_dump_time = dump_time
                    last_process_times = process_times
                    stats = Hash.new

		    @cycle_start += cycle_length
		    @cycle_index += 1

		rescue Exception => e
                    if !quitting?
                        quit

                        ExecutionEngine.fatal "Execution thread quitting because of unhandled exception"
                        Roby.display_exception(ExecutionEngine.logger.io(:fatal), e)
                    elsif !e.kind_of?(Interrupt)
                        ExecutionEngine.fatal "Execution thread FORCEFULLY quitting because of unhandled exception"
                        Roby.display_exception(ExecutionEngine.logger.io(:fatal), e)
                        raise
                    end
                ensure
                    log_timepoint_group_end "cycle"
		end
	    end

	ensure
	    if !plan.tasks.empty?
		ExecutionEngine.warn "the following tasks are still present in the plan:"
		plan.tasks.each do |t|
		    ExecutionEngine.warn "  #{t}"
		end
	    end
	end

        # Set the cycle_start attribute and increment cycle_index
        #
        # This is only used for testing purposes
        def start_new_cycle(time = Time.now)
            @cycle_start = time
            @cycle_index += 1
        end

        # A set of proc objects which are to be called when the execution engine
        # quits.
        attr_reader :finalizers

	# True if the control thread is currently quitting
	def quitting?; @quit > 0 end
	# True if the control thread is currently quitting
	def forced_exit?; @quit > 1 end
	# Make control quit properly
	def quit; @quit = 1 end
        # Force quitting, without cleaning up
        def force_quit; @quit = 2 end

        # Make a quit EE ready for reuse
        def reset
            @quit = 0
        end

	# Called at each cycle end
	def cycle_end(stats)
            gather_framework_errors('#cycle_end') do
                at_cycle_end_handlers.each do |handler|
                    handler.call(self)
                end
            end
	end

        # Block until the given block is executed by the execution thread, at
        # the beginning of the event loop, in propagation context. If the block
        # raises, the exception is raised back in the calling thread.
        def execute(type: :external_events)
	    if inside_control?
		return yield
	    end

            ivar = Concurrent::IVar.new
            once(sync: ivar, type: type) do
                begin
                    ivar.set(yield)
                rescue ::Exception => e
                    ivar.fail(e)
                end
            end
            ivar.value!
        end

        # Stops the current thread until the given even is emitted. If the event
        # becomes unreachable, an UnreachableEvent exception is raised.
        def wait_until(ev)
            if inside_control?
                raise ThreadMismatch, "cannot use #wait_until in execution threads"
            end

            ivar = Concurrent::IVar.new
            once(sync: ivar) do
                ev.if_unreachable(cancel_at_emission: true) do |reason, event|
                    ivar.fail(UnreachableEvent.new(event, reason))
                end
                ev.on do |ev|
                    ivar.set(true)
                end
                yield if block_given?
            end
            ivar.value!
        end

        def shutdown
            killall
            thread_pool.shutdown
        end

        # Kill all tasks that are currently running in the plan
        def killall
            scheduler_enabled = scheduler.enabled?

            plan.permanent_tasks.clear
            plan.permanent_events.clear
            plan.mission_tasks.clear

            scheduler.enabled = false
            quit

            start_new_cycle
            process_events
            cycle_end(Hash.new)

            plan.transactions.each do |trsc|
                trsc.discard_transaction!
            end

            start_new_cycle
            Thread.pass
            process_events
            cycle_end(Hash.new)

        ensure
            scheduler.enabled = scheduler_enabled
        end

        # Exception kind passed to {#on_exception} handlers for non-fatal,
        # unhandled exceptions
	EXCEPTION_NONFATAL = :nonfatal

        # Exception kind passed to {#on_exception} handlers for fatal,
        # unhandled exceptions
	EXCEPTION_FATAL    = :fatal

        # Exception kind passed to {#on_exception} handlers for handled
        # exceptions
	EXCEPTION_HANDLED  = :handled

        # Exception kind passed to {#on_exception} handlers for free event
        # exceptions
        EXCEPTION_FREE_EVENT = :free_event

	# Registers a callback that will be called when exceptions are propagated in the plan
	#
        # @yieldparam [Symbol] kind one of {EXCEPTION_NONFATAL},
        #   {EXCEPTION_FATAL}, {EXCEPTION_FREE_EVENT} or {EXCEPTION_HANDLED}
        # @yieldparam [Roby::ExecutionException] error the exception
        # @yieldparam [Array<Roby::Task>] tasks the tasks that are involved in this exception
        #
        # @return [Object] an ID that can be used as argument to {#remove_exception_listener}
	def on_exception(description: 'exception listener', &block)
            handler = PollBlockDefinition.new(description, block, on_error: :disable)
	    exception_listeners << handler
	    handler
	end

        # Controls whether this engine should indiscriminately display all fatal
        # exceptions
        #
        # This is on by default
        def display_exceptions=(flag)
            if flag
                @exception_display_handler ||= on_exception do |kind, error, tasks|
                    level = if kind == EXCEPTION_HANDLED then :debug
                            else :warn
                            end

                    send(level) do
                        send(level, "encountered a #{kind} exception")
                        Roby.log_exception_with_backtrace(error.exception, self, level)
                        if kind == EXCEPTION_HANDLED
                            send(level, "the exception was handled by")
                        else
                            send(level, "the exception involved")
                        end
                        tasks.each do |t|
                            send(level, "  #{t}")
                        end
                        break
                    end
                end
            else
                remove_exception_listener(@exception_display_handler)
                @exception_display_handler = nil
            end
        end

        # whether this engine should indiscriminately display all fatal
        # exceptions
        def display_exceptions?
            !!@exception_display_handler
        end

	# Removes an exception listener registered with {#on_exception}
	#
	# @param [Object] the value returned by {#on_exception}
	# @return [void]
	def remove_exception_listener(handler)
	    exception_listeners.delete(handler)
	end

	# Call to notify the listeners registered with {#on_exception} of the
	# occurence of an exception
	def notify_exception(kind, error, involved_objects)
            log(:exception_notification, plan.droby_id, kind, error, involved_objects)
	    exception_listeners.each do |listener|
		listener.call(self, kind, error, involved_objects)
	    end
	end

        # Create a promise to execute the given block in a separate thread
        #
        # Note that the returned value is a {Roby::Promise}. This means that
        # callbacks added with #on_success or #rescue will be executed in the
        # execution engine thread by default.
        def promise(description: nil, executor: thread_pool, &block)
            Promise.new(self, executor: thread_pool, description: description, &block)
        end
    end

    # Execute the given block in the main plan's propagation context, but don't
    # wait for its completion like Roby.execute does
    #
    # See ExecutionEngine#once
    def self.once; execution_engine.once { yield } end

    # Make the main engine call +block+ during each propagation step.
    # See ExecutionEngine#each_cycle
    def self.each_cycle(&block); execution_engine.each_cycle(&block) end

    # Install a periodic handler on the main engine
    def self.every(duration, options = Hash.new, &block); execution_engine.every(duration, options, &block) end

    # True if the current thread is the execution thread of the main engine
    #
    # See ExecutionEngine#inside_control?
    def self.inside_control?; execution_engine.inside_control? end

    # True if the current thread is not the execution thread of the main engine
    #
    # See ExecutionEngine#outside_control?
    def self.outside_control?; execution_engine.outside_control? end

    # Execute the given block during the event propagation step of the main
    # engine. See ExecutionEngine#execute
    def self.execute
        execution_engine.execute do
            yield
        end
    end

    # Blocks until the main engine has executed at least one cycle.
    # See ExecutionEngine#wait_one_cycle
    def self.wait_one_cycle; execution_engine.wait_one_cycle end

    # Stops the current thread until the given even is emitted. If the event
    # becomes unreachable, an UnreachableEvent exception is raised.
    #
    # See ExecutionEngine#wait_until
    def self.wait_until(ev, &block); execution_engine.wait_until(ev, &block) end
end


