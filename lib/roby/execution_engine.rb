module Roby
    # Exception wrapper used to report that multiple errors have been raised
    # during a synchronous event processing call.
    # 
    # See ExecutionEngine#process_events_synchronous for more information
    class SynchronousEventProcessingMultipleErrors < RuntimeError
        attr_reader :errors
        def initialize(errors)
            @errors = errors
        end
    end

    # This class contains all code necessary for the propagation steps during
    # execution. This includes event and exception propagation. This
    # documentation will first present some useful tools provided by execution
    # engines, and will continue by an overview of the implementation of the
    # execution engine itself.
    #
    # == Misc tools
    #
    # === Block execution queueing
    # <em>periodic handlers</em> are code blocks called at the beginning of the
    # execution cycle, at the given periodicity (of course rounded to a cycle
    # length). They are added by #every and removed by
    # #remove_periodic_handler.
    #
    # === Thread synchronization primitives
    # Most direct plan modifications and propagation operations are forbidden
    # outside the execution engine's thread, to avoid the need for handling
    # asynchronicity. Nonetheless, it is possible that a separate thread has to
    # execute some of those operations. To simplify that, the following methods
    # are available:
    # * #execute blocks the calling thread until the given code
    #   block is executed by the execution engine. Any exception that is raised
    #   by the code block is raised back into the original thread and will not
    #   affect the engine thread.
    # * #once queues a block to be executed at the beginning of
    #   the next execution cycle. Exceptions raised in it _will_ affect the
    #   execution thread and most likely cause its shutdown.
    # * #wait_until(ev) blocks the calling thread until +ev+ is emitted. If +ev+
    #   becomes unreachable, an UnreachableEvent exception is raised in the
    #   calling thread.
    #
    # To simplify the controller development, those tools are available directly
    # as singleton methods of the Roby module, which forwards them to the
    # main execution engine. One can for instance do
    #   Roby.once { puts "start of the execution thread" }
    #
    # Instead of
    #   Roby.app.plan.engine.once { ... }
    #
    # Or 
    #   engine.once { ... }
    #
    # Nonetheless, note that it breaks the object-orientation of the system and
    # therefore won't work in cases where you want multiple execution engines to
    # run in parallel.
    #
    # == Execution cycle
    #
    # link:../../images/roby_cycle_overview.png
    #
    # === Event propagation
    # Event propagation is based on three main event relations:
    #
    # * Signal describes the commands that must be called when an event occurs. The
    #   signalled event command is called when the signalling events are emitted. If
    #   more than one event are signalling the same event in the same execution
    #   cycle, the command will be called only once.
    # * Forwarding describes the events that must be emitted whenever a source
    #   event is emitted. It is to be used as a way to define event aliases (for instance
    #   'stop' is an alias for 'success'), because a task is stopped when it has
    #   finished with success. Unlike with signals, if more than one event is
    #   forwarded to the same event in the same cycle, the target event will be
    #   emitted as many times as the incoming events.
    # * the Precedence relation is a subset of the two preceding relations. It
    #   represents a partial ordering of the events that must be maintained during
    #   the propagation stage (i.e. a notion of causality).
    #
    # In the code, the following procedure applies: when a code fragment calls
    # EventGenerator#emit or EventGenerator#call, the event is not emitted right
    # away. Instead, it is queued in the set of "pending" events through the use of
    # #add_event_propagation. The execution engine will then consider
    # the pending set of events, choose the appropriate one by following the
    # information contained in the Precedence relation and emit or call it. The
    # actual call/emission is done through EventGenerator#call_without_propagation
    # and EventGenerator#emit_without_propagation. The error checking (i.e. wether
    # or not the emission/call is allowed) is done at both steps of propagation,
    # because doing it late in the *_without_propagation versions would make the
    # system more difficult to debug/test.
    #
    # === Error handling
    # Each user-provided code fragment (i.e. event handlers, event commands,
    # polling blocks, ...) are called into a specific error-gathering context.
    # Once an exception is caught, it is added to the set of detected errors
    # through #add_error. Those errors are handled after the
    # event propagation cycle by the #propagate_exceptions
    # method. It follows the following steps:
    #
    # * it removes all exceptions for which a running repair exists
    #   (#remove_inhibited_exceptions)
    #
    # * it checks for repairs declared through the
    #   Roby::TaskStructure::ErrorHandling relation. If one exists, the
    #   corresponding task is started, adds it to the set of running repairs
    #   (Plan#add_repair)
    #
    #   For example, the following code fragment declares that +repair_task+ 
    #   is a plan repair for all errors involving the +low_battery+ event of the
    #   +moving+ task
    #
    #       task.event(:moving).handle_with repair_task
    #
    # * it executes the exception handlers that have been declared for this
    #   exception by a call to Roby::Task.on_exception.  The following code
    #   fragment defines an exception handler for LowBattery exceptions:
    #
    #       class Moving
    #           on_exception(LowBattery) { |error| do_something_to_handle_that }
    #       end
    #
    #   Exception handling is finished whenever an exception handler did not
    #   call #pass_exception to notify that it cannot handle the given
    #   exception.
    #
    # * if no exception handler is found, or if all of them called
    #   #pass_exception, then plan-level exception handlers are searched in the
    #   corresponding Roby::Plan instance. Plan-level exception handlers are
    #   defined by Plan#on_exception. Alternatively, for the main plan,
    #   Roby.on_exception can be also used.
    #
    # * finally, tasks that are still involved in an error are injected into the
    #   garbage collection process through the +force+ argument of
    #   #garbage_collect, so that they get killed and removed from the plan.
    #
    class ExecutionEngine
        extend Logger::Hierarchy
        include Logger::Hierarchy

        # Create an execution engine acting on +plan+, using +control+ as the
        # decision control object
        #
        # See Roby::Plan and Roby::DecisionControl
        def initialize(plan, control = Roby::DecisionControl.new)
            @plan = plan
            plan.engine = self
            @control = control

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
            @waiting_threads = Array.new
            @emitted_events  = Array.new
            @disabled_handlers = ValueSet.new
            @additional_errors = nil
            @exception_listeners = Array.new

            @worker_threads_mtx = Mutex.new
            @worker_threads = Array.new
            @worker_completion_blocks = Queue.new

	    each_cycle(&ExecutionEngine.method(:call_every))

	    @quit        = 0
            @allow_propagation = true
	    @thread      = nil
	    @cycle_index = 0
	    @cycle_start = Time.now
	    @cycle_length = 0
	    @last_stop_count = 0
            @finalizers = []
            @gc_warning = true
	end

        # The Plan this engine is acting on
        attr_accessor :plan
        # The DecisionControl object associated with this engine
        attr_accessor :control
        # A numeric ID giving the count of the current propagation cycle
        attr_reader :propagation_id
        # The set of events that have been emitted in the current execution
        # cycle
        attr_reader :emitted_events
        # The blocks that are currently listening to exceptions
        # @return [Array<#call>]
        attr_reader :exception_listeners
        # @return [Queue] blocks queued for execution in the next cycle by
        #   {#queue_worker_completion_block}
        attr_reader :worker_completion_blocks

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

            def initialize(description, handler, options)
                options = Kernel.validate_options options,
                    :on_error => :raise, :late => false, :once => false

                if !PollBlockDefinition::ON_ERROR.include?(options[:on_error].to_sym)
                    raise ArgumentError, "invalid value '#{options[:on_error]} for the :on_error option. Accepted values are #{ON_ERROR.map(&:to_s).join(", ")}"
                end

                @description, @handler, @on_error, @late, @once =
                    description, handler, options[:on_error], options[:late], options[:once]
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
        
        @propagation_handlers = []
        @external_events_handlers = []
        class << self
            # Code blocks that get called at the beginning of each cycle
            attr_reader :external_events_handlers
            # Code blocks that get called during propagation to handle some
            # internal propagation mechanism
            attr_reader :propagation_handlers

            # The propagation handlers are blocks that should be called at
            # various places during propagation for all plans. These objects
            # are called in propagation context, which means that the events
            # they would call or emit are injected in the propagation process
            # itself.
            #
            # @option options [:external_events,:propagation] type defines when
            #   this block should be called. If :external_events, it is called
            #   only once at the beginning of each execution cycle. If
            #   :propagation, it is called once at the beginning of each cycle,
            #   as well as after each propagation step. The :late option also
            #   gives some control over when the handler is called when in
            #   propagation mode
            # @option options [Boolean] once (false) if true, this handler will
            #   be removed just after its first execution
            # @option options [Boolean] late (false) if true, the handler is
            #   called only when there are no events to propagate anymore.
            # @option options [:raise,:ignore,:disable] on_error (:raise)
            #   controls what happens when the block raises an exception. If
            #   :raise, the error is registered as a framework error. If
            #   :ignore, it is completely ignored. If :disable, the handler
            #   will be disabled, i.e. not called anymore until #disabled?
            #   is set to false.
            #
            # @see ExecutionEngine.remove_propagation_handler
            def add_propagation_handler(options = Hash.new, &block)
                if options.respond_to?(:call) # for backward compatibility
                    block, options = options, Hash.new
                end

                handler_options, poll_options = Kernel.filter_options options,
                    :type => :external_events

                check_arity block, 1
                new_handler = PollBlockDefinition.new("propagation handler #{block}", block, poll_options)

                if handler_options[:type] == :propagation
                    propagation_handlers << new_handler
                elsif handler_options[:type] == :external_events
                    if new_handler.late?
                        raise ArgumentError, "only :propagation handlers can be marked as 'late', the external event handlers cannot"
                    end
                    external_events_handlers << new_handler
                else
                    raise ArgumentError, "invalid value for the :type option. Expected :propagation or :external_events, got #{handler_options[:type]}"
                end
                new_handler.id
            end
            
            # This method removes a propagation handler which has been added by
            # ExecutionEngine.add_propagation_handler.  THe +id+ value is the
            # value returned by ExecutionEngine.add_propagation_handler.
            def remove_propagation_handler(id)
                propagation_handlers.delete_if { |p| p.id == id }
                external_events_handlers.delete_if { |p| p.id == id }
                disabled_handlers.delete_if { |p| p.id == id }
                nil
            end
        end

        # A set of block objects that are called repeatedly during the
        # propagation phase, until no propagations are needed anymore
        #
        # These objects are called in propagation context, which means that the
        # events they would call or emit are injected in the propagation process
        # itself.
        attr_reader :propagation_handlers

        # A set of block objects that are once at the beginning of each
        # execution cycle.
        #
        # These objects are called in propagation context, which means that the
        # events they would call or emit are injected in the propagation process
        # itself.
        attr_reader :external_events_handlers
        
        # The propagation handlers are blocks that should be called at
        # various places during propagation for all plans. These objects
        # are called in propagation context, which means that the events
        # they would call or emit are injected in the propagation process
        # itself.
        #
        # @option options [:external_events,:propagation] type defines when
        #   this block should be called. If :external_events, it is called
        #   only once at the beginning of each execution cycle. If
        #   :propagation, it is called once at the beginning of each cycle,
        #   as well as after each propagation step. The :late option also
        #   gives some control over when the handler is called when in
        #   propagation mode
        # @option options [Boolean] once (false) if true, this handler will
        #   be removed just after its first execution
        # @option options [Boolean] late (false) if true, the handler is
        #   called only when there are no events to propagate anymore.
        # @option options [:raise,:ignore,:disable] on_error (:raise)
        #   controls what happens when the block raises an exception. If
        #   :raise, the error is registered as a framework error. If
        #   :ignore, it is completely ignored. If :disable, the handler
        #   will be disabled, i.e. not called anymore until #disabled?
        #   is set to false.
        #
        # @see ExecutionEngine#remove_propagation_handler
        def add_propagation_handler(options = Hash.new, &block)
            if options.respond_to?(:call) # for backward compatibility
                block, options = options, Hash.new
            end

            handler_options, poll_options = Kernel.filter_options options,
                :type => :external_events

            check_arity block, 1
            new_handler = PollBlockDefinition.new("propagation handler #{block}", block, poll_options)

            if handler_options[:type] == :propagation
                propagation_handlers << new_handler
            elsif handler_options[:type] == :external_events
                external_events_handlers << new_handler
            else
                raise ArgumentError, "invalid value for the :type option. Expected :propagation or :external_events, got #{handler_options[:type]}"
            end
            new_handler.id
        end

        # This method removes a propagation handler which has been added by
        # #add_propagation_handler.  THe +id+ value is the value returned by
        # #add_propagation_handler. In its first form, the argument is the proc
        # object to be added. In the second form, the block is taken the
        # handler. In both cases, the method returns a value which can be used
        # to remove the propagation handler later.
        #
        # See also #add_propagation_handler
        def remove_propagation_handler(id)
            propagation_handlers.delete_if { |p| p.id == id }
            external_events_handlers.delete_if { |p| p.id == id }
            nil
        end

        # Registers a thread on {#worker_threads}
        def register_worker_thread(thread)
            @worker_threads_mtx.synchronize do
                worker_threads << thread
            end
        end

        # Removes the dead workers from {#worker_threads} 
        def cleanup_worker_threads
            @worker_threads_mtx.synchronize do
                worker_threads.delete_if { |t| !t.alive? }
            end
        end

        # Adds a block to be called at the beginning of the next execution cycle
        #
        # Unlike {#once}, it is thread-safe
        def queue_worker_completion_block(&block)
            worker_completion_blocks << block
        end

        # Waits for all threads in {#worker_threads} to finish
        #
        # It will not reflect the exceptions thrown by the thread
        def join_all_worker_threads
            threads = @worker_threads_mtx.synchronize do
                worker_threads.dup
            end
            threads.each do |t|
                begin t.join
                rescue Exception
                end
            end
        end

        # call-seq:
        #   engine.each_cycle { |plan| ... }
        #
        # Execute the given block at the beginning of each cycle, in propagation
        # context.
        #
        # The returned value is an ID that can be used to remove the handler using
        # #remove_propagation_handler
        #
        # System-wide handlers, which should be executed in all engines, can be
        # defined with ExecutionEngine.add_propagation_handler and removed by
        # ExecutionEngine.remove_propagation_handler
        def each_cycle(&block)
            add_propagation_handler(block)
        end

        # The scheduler is the object which handles non-generic parts of the
        # propagation cycle.  For now, its #initial_events method is called at
        # the beginning of each propagation cycle and can call or emit a set of
        # events.
        #
        # See Schedulers::Basic
        attr_accessor :scheduler

        # True if we are currently in the propagation stage
        def gathering?; !!@propagation end

        attr_predicate :allow_propagation

        # The set of source events for the current propagation action. This is a
        # mix of EventGenerator and Event objects.
        attr_reader :propagation_sources
        # The set of events extracted from #sources
        def propagation_source_events
            result = ValueSet.new
            for ev in @propagation_sources
                if ev.respond_to?(:generator)
                    result << ev
                end
            end
            result
        end

        # The set of generators extracted from #sources
        def propagation_source_generators
            result = ValueSet.new
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

        # Called by #plan when an event became unreachable
        def unreachable_event(event)
            delayed_events.delete_if { |_, _, _, signalled, _| signalled == event }
            super if defined? super
        end

        # Called by #plan when an event has been finalized
        def finalized_event(event)
            event.unreachable!(nil, plan)
            # since the event is already finalized, 
            super if defined? super
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
                @propagation_step_id = 0

                before = @propagation
                propagation_context(nil) { yield }

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

        # If called in execution context, adds the plan-based error +e+ to be
        # handled later in the execution cycle. Otherwise, calls
        # #add_framework_error
        def add_error(e)
            plan_exception = e.to_execution_exception
            if @additional_errors
                # We are currently propagating exceptions. Gather new ones in
                # @additional_errors
                @additional_errors << e
            elsif @propagation_exceptions
                @propagation_exceptions << plan_exception
            else
                process_events_synchronous([], [plan_exception])
            end
        end

        # Yields to the block, calling #add_framework_error if an exception is
        # raised 
        def gather_framework_errors(source)
            if @application_exceptions
                has_application_errors = true
            else
                @application_exceptions = []
            end
            yield
        rescue Exception => e
            add_framework_error(e, source)
        ensure
            if !has_application_errors
                process_pending_application_exceptions
            end
        end

        def process_pending_application_exceptions
            application_errors, @application_exceptions = 
                @application_exceptions, nil
            for error, origin in application_errors
                add_framework_error(error, origin)
            end
        end

        # If called in execution context, adds the framework error +error+ to be
        # handled later in the execution cycle. Otherwise, either raises the
        # error again if Application#abort_on_application_exception is true. IF
        # abort_on_application_exception is false, simply displays a warning
        def add_framework_error(error, source)
            if @application_exceptions
                @application_exceptions << [error, source]
            elsif Roby.app.abort_on_application_exception? || error.kind_of?(SignalException)
                raise error, "in #{source}: #{error.message}", error.backtrace
            else
                ExecutionEngine.error "Application error in #{source}"
                Roby.format_exception(error).each do |line|
                    Roby.warn line
                end
            end
        end

        # Sets the source_event and source_generator variables according
        # to +source+. +source+ is the +from+ argument of #add_event_propagation
        def propagation_context(sources)
            raise InternalError, "not in a gathering context in #fire" unless gathering?

            if sources
                current_sources = @propagation_sources
                @propagation_sources = sources
            else
                @propagation_sources = []
            end

            yield @propagation

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

        # Adds a propagation to the next propagation step: it registers a
        # propagation step to be performed between +source+ and +target+ with
        # the given +context+. If +is_forward+ is true, the propagation will be
        # a forwarding, otherwise it is a signal.
        #
        # If +timespec+ is not nil, it defines a delay to be applied before
        # calling the target event.
        #
        # See #gather_propagation
        def add_event_propagation(is_forward, from, target, context, timespec)
            if target.plan != plan
                raise Roby::EventNotExecutable.new(target), "#{target} not in executed plan"
            end

            @propagation_step_id += 1

            step = (@propagation[target] ||= [@propagation_step_id, nil, nil])
            from = [nil] unless from && !from.empty?

            step = if is_forward then (step[1] ||= [])
                   else (step[2] ||= [])
                   end

            from.each do |ev|
                step << ev << context << timespec
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

                if !handler.call(self, plan)
                    handler.disabled = true
                end
                handler.once?
            end
        end

        # Process the pending worker completion blocks
        def process_workers
            cleanup_worker_threads

            completion_blocks = []
            while !worker_completion_blocks.empty?
                block = worker_completion_blocks.pop
                completion_blocks << PollBlockDefinition.new("worker completion handler #{block}", block, Hash.new)
            end
            call_poll_blocks(completion_blocks)
        end

        # Gather the events that come out of this plan manager
        def gather_external_events
            gather_framework_errors('distributed events') { Roby::Distributed.process_pending }
            gather_framework_errors('delayed events')     { execute_delayed_events }
            call_poll_blocks(self.class.external_events_handlers)
            call_poll_blocks(self.external_events_handlers)
        end

        def call_propagation_handlers
            if scheduler && scheduler.enabled?
                gather_framework_errors('scheduler') do
                    report_scheduler_state(scheduler.state)
                    scheduler.clear_reports
                    scheduler.initial_events
                end
            end
            call_poll_blocks(self.class.propagation_handlers, false)
            call_poll_blocks(self.propagation_handlers, false)

            if !has_queued_events?
                call_poll_blocks(self.class.propagation_handlers, true)
                call_poll_blocks(self.propagation_handlers, true)
            end
        end

        # Called whenever the scheduler did something, to report about its state
        def report_scheduler_state(state)
            super if defined? super
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
        
        def error_handling_phase(stats, events_errors)
            # Do the exception handling phase
            fatal_errors = compute_fatal_errors(stats, events_errors)
            return if fatal_errors.empty?

            kill_tasks = fatal_errors.inject(Set.new) do |tasks, (exception, affected_tasks)|
                tasks | (affected_tasks || exception.trace).to_set
            end
            kill_tasks.delete_if do |t|
                !t.plan
            end

            fatal_errors.each do |e, tasks|
                fatal_exception(e, tasks)
            end

            if !kill_tasks.empty?
                warn do
                    warn "will kill the following #{kill_tasks.size} tasks because of unhandled exceptions:"
                    kill_tasks.each do |task|
                        log_pp :warn, task
                    end
                    break
                end

                return kill_tasks, fatal_errors
            else
                nil
            end
        end

        # Validates +timespec+ as a delay specification. A valid delay
        # specification is either +nil+ or a hash, in which case two forms are
        # possible:
        #
        #   :at => absolute_time
        #   :delay => number
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
                target_priority = if forwards && signals then 1
                                  elsif signals then 0
                                  else 2
                                  end

                do_select = if selected_event
                                if EventStructure::Precedence.reachable?(selected_event, target_event)
                                    false
                                elsif EventStructure::Precedence.reachable?(target_event, selected_event)
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

            source_events, source_generators, context = ValueSet.new, ValueSet.new, []

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
                [source_events, source_generators, (context unless context.empty?)]
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
            if call_info
                source_events, source_generators, context = prepare_propagation(signalled, false, call_info)
                if source_events
                    for source_ev in source_events
                        source_ev.generator.signalling(source_ev, signalled)
                    end

                    if signalled.self_owned?
                        next_step = gather_propagation(current_step) do
                            propagation_context(source_events | source_generators) do |result|
                                begin
                                    signalled.call_without_propagation(context) 
                                rescue Roby::EventNotExecutable => e
                                    add_error(e)
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
                    next_step[signalled] ||= [@propagation_step_id += 1, nil, nil]
                    next_step[signalled][1] ||= []
                    next_step[signalled][1].concat forward_info
                end

            elsif forward_info
                source_events, source_generators, context = prepare_propagation(signalled, true, forward_info)
                if source_events
                    for source_ev in source_events
                        source_ev.generator.forwarding(source_ev, signalled)
                    end

                    # If the destination event is not owned, but if the peer is not
                    # connected, the event is our responsibility now.
                    if signalled.self_owned? || !signalled.owners.any? { |peer| peer != Roby::Distributed && peer.connected? }
                        next_step = gather_propagation(current_step) do
                            propagation_context(source_events | source_generators) do |result|
                                begin
                                    event = signalled.emit_without_propagation(context)
                                    emitted_events << event
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
            # Remove all exception that are not associated with a task
            exceptions = exceptions.find_all do |e, _|
                if !e.origin
                    Roby.display_exception(Roby.logger.io(:warn), e.exception)
                    e.generator.unreachable!(e.exception)
                    false
                else true
                end
            end

            # Propagate the exceptions in the hierarchy
            handled_exceptions = Hash.new
            unhandled = Array.new
            propagation = lambda do |from, to, e|
                e.trace << to
                e
            end
            visitor = lambda do |task, e|
                e.handled = yield(e, task)
                if e.handled?
                    debug { "handled by #{task}" }
                    handled_exception(e, task)
                    handled_exceptions[e.exception] << e
                    TaskStructure::Dependency.prune
                else
                    debug { "not handled by #{task}" }
                end
            end

            exceptions.each do |exception, parents|
                parents = [] if !parents
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

                origin = exception.origin
                filtered_parents = parents.find_all { |t| t.depends_on?(origin) }
                if filtered_parents != parents
                    warn "some parents specified for #{exception.exception}(#{exception.exception.class}) are actually not parents of #{origin}, they got filtered out"
                    (parents - filtered_parents).each do |task|
                        warn "  #{task}"
                    end
                end
                parents = filtered_parents
                handled_exceptions[exception.exception] = Set.new
                remaining = TaskStructure::Dependency.reverse.
                    fork_merge_propagation(origin, exception, :vertex_visitor => visitor) do |from, to, e|
                        if !parents.empty?
                            if from == origin && !parents.include?(to)
                                TaskStructure::Dependency.prune
                            end
                        end
                        e.trace << to
                        e
                    end

                remaining.each_value do |unhandled_exception|
                    unhandled << unhandled_exception
                end
            end

            # Call global exception handlers for exceptions in +fatal+. Return the
            # set of still unhandled exceptions
            unhandled = unhandled.find_all do |e|
                e.handled = yield(e, plan)
                if e.handled?
                    handled_exceptions[e.exception] << e
                    handled_exception(e, plan)
                end
                !e.handled?
            end

            # Finally, compute the set of tasks that are affected by the
            # unhandled exceptions
            unhandled = unhandled.map do |e|
                affected_tasks = e.trace.dup
                handled_exceptions[e.exception].each do |handled_e|
                    affected_tasks -= handled_e.trace
                end
                [e, affected_tasks]
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
            unhandled
        end

        # Propagation exception phase, checking if tasks and/or the main plan
        # are handling the exceptions
        #
        # @param [Array<(ExecutionException,Array<Task>)>] exceptions the set of
        #   exceptions to propagate, as well as the parents that towards which
        #   we should propagate them (if empty, all parents)
        # @return (see propagate_exception_in_plan)
        def propagate_exceptions(exceptions)
            debug "Filtering inhibited exceptions"
            exceptions = log_nest(2) do
                non_inhibited = remove_inhibited_exceptions(exceptions)
                exceptions.find_all do |exception, _|
                    exception.reset_trace
                    non_inhibited.any? { |e, _| e.exception == exception.exception }
                end
            end

            debug "Propagating #{exceptions.size} non-inhibited exceptions"
            log_nest(2) do
                propagate_exception_in_plan(exceptions) do |e, object|
                    object.handle_exception(e)
                end
            end
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
            propagate_exception_in_plan(exceptions) do |e, object|
                if plan.force_gc.include?(object)
                    true
                elsif object.respond_to?(:handles_error?)
                    object.handles_error?(e)
                end
            end
        end

        # Schedules +block+ to be called at the beginning of the next execution
        # cycle, in propagation context.
        #
        # @yieldparam [Plan] plan the plan on which this engine works
        def once(options = Hash.new, &block)
            add_propagation_handler(Hash[:type => :external_events, :once => true].merge(options), &block)
        end

        # Schedules +block+ to be called once after +delay+ seconds passed, in
        # the propagation context
        def delayed(delay, options = Hash.new, &block)
            handler = PollBlockDefinition.new("delayed block #{block}", block, Hash[:once => true].merge(options))
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

        def compute_fatal_errors(stats, events_errors)
            # Generate exceptions from task structure
            structure_errors = plan.check_structure
            add_timepoint(stats, :structure_check)

            if @additional_errors
                raise InternalError, "recursive call to #compute_fatal_errors"
            end
            @additional_errors = Array.new

            # Propagate the errors. Note that the plan repairs are taken into
            # account in ExecutionEngine.propagate_exceptions directly.  We keep
            # event and structure errors separate since in the first case there
            # is not two-stage handling (all errors that have not been handled
            # are fatal), and in the second case we call #check_structure
            # again to get the remaining errors
            events_errors    = propagate_exceptions(events_errors)
            propagate_exceptions(structure_errors)

            unhandled_additional_errors = Array.new
            10.times do
                break if additional_errors.empty?
                errors, @additional_errors = additional_errors, Array.new
                unhandled_additional_errors.concat(propagate_exceptions(plan.format_exception_set(Hash.new, errors)).to_a)
            end
            @additional_errors = nil

            add_timepoint(stats, :exception_propagation)

            # Get the remaining problems in the plan structure, and act on it
            fatal_errors = remove_inhibited_exceptions(plan.check_structure)
            # Add events_errors and unhandled_additional_errors to fatal_errors.
            # Note that all the objects in fatal_errors now have a proper trace
            fatal_errors.concat(events_errors.to_a)
            fatal_errors.concat(unhandled_additional_errors.to_a)

            # Partition between fatal and non-fatal errors. Simply log & notify
            # for the nonfatal ones
            nonfatal = []
            fatal_errors.delete_if do |e, tasks|
                if !e.fatal?
                    nonfatal << [e, tasks]
                end
            end
            if !nonfatal.empty?
                warn "unhandled #{nonfatal.size} non-fatal exceptions"
                nonfatal.each do |e, tasks|
                    nonfatal_exception(e, tasks)
                end
            end

            debug "#{fatal_errors.size} fatal errors found"
            fatal_errors
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
        def process_events_synchronous(seeds = Hash.new, initial_errors = Array.new)
            gather_framework_errors("process_events_simple") do
                stats = Hash[:start => Time.now]
                next_steps = seeds.dup
                errors = initial_errors.dup
                if block_given?
                    if !seeds.empty?
                        raise ArgumentError, "cannot give both seeds and block"
                    end

                    next_steps = gather_propagation do
                        new_errors = gather_errors do
                            proc.call
                        end
                        errors.concat(new_errors)
                    end
                end

                if next_steps.empty? && errors.empty?
                    next_steps = gather_propagation do
                        error_handling_phase_synchronous(stats, errors)
                    end
                end

                while !next_steps.empty? || !errors.empty?
                    errors.concat(event_propagation_phase(next_steps))
                    next_steps = gather_propagation do
                        error_handling_phase_synchronous(stats, errors)
                        errors.clear
                    end
                end
            end
        end

        def error_handling_phase_synchronous(stats, errors)
            kill_tasks, fatal_errors = error_handling_phase(stats, errors || [])
            if fatal_errors
                fatal_errors.each do |e, _|
                    Roby.display_exception(Roby.logger.io(:warn), e.exception)
                end
                if fatal_errors.size == 1
                    e = fatal_errors.first.first.exception
                    raise e.dup, e.message, e.backtrace
                elsif !fatal_errors.empty?
                    raise SynchronousEventProcessingMultipleErrors.new(fatal_errors), "multiple exceptions in synchronous propagation"
                end
            end
        end

        def garbage_collect_synchronous
            known_tasks_size = nil
            while plan.known_tasks.size != known_tasks_size
                if !known_tasks_size
                    known_tasks_size = true
                else
                    known_tasks_size = plan.known_tasks.size
                end
                process_events_synchronous do
                    garbage_collect([])
                end
            end
        end
        
        # Process the pending events. The time at each event loop step
        # is saved into +stats+.
        def process_events(stats = {:start => Time.now})
            if @application_exceptions
                raise "recursive call to process_events"
            end
            @application_exceptions = []
            add_timepoint(stats, :real_start)

            # Gather new events and propagate them
	    events_errors = nil
            next_steps = gather_propagation do
	        events_errors = gather_errors do
                    if quitting?
                        garbage_collect([])
                    end
                    process_workers
                    gather_external_events
                    call_propagation_handlers
	        end
            end

            all_fatal_errors = Array.new
            if next_steps.empty?
                next_steps = gather_propagation do
                    kill_tasks, fatal_errors = error_handling_phase(stats, events_errors)
                    add_timepoint(stats, :exceptions_fatal)
                    if fatal_errors
                        all_fatal_errors.concat(fatal_errors)
                    end

                    events_errors = gather_errors do
                        garbage_collect(kill_tasks)
                    end
                    add_timepoint(stats, :garbage_collect)
                end
            end

            while !next_steps.empty? || !events_errors.empty?
                events_errors.concat(event_propagation_phase(next_steps))
                add_timepoint(stats, :events)

                next_steps = gather_propagation do
                    kill_tasks, fatal_errors = error_handling_phase(stats, events_errors)
                    add_timepoint(stats, :exceptions_fatal)
                    if fatal_errors
                        all_fatal_errors.concat(fatal_errors)
                    end

                    events_errors = gather_errors do
                        garbage_collect(kill_tasks)
                    end
                    add_timepoint(stats, :garbage_collect)
                end
            end

            process_pending_application_exceptions

            if Roby.app.abort_on_exception? && !all_fatal_errors.empty?
                reraise(all_fatal_errors.map { |e, _| e })
            end

        ensure
            @application_exceptions = nil
        end

        # Hook called when an unhandled nonfatal exception has been found
        def nonfatal_exception(error, tasks)
            super if defined? super
            Roby.format_exception(error.exception).each do |line|
                ExecutionEngine.warn line
            end
	    notify_exception(EXCEPTION_NONFATAL, error, tasks)
        end

        # Hook called when a set of tasks is being killed because of an exception
        def fatal_exception(error, tasks)
            super if defined? super
            Roby.format_exception(error.exception).each do |line|
                ExecutionEngine.warn line
            end
	    notify_exception(EXCEPTION_FATAL, error, tasks)
        end

        # Hook called when an exception +e+ has been handled by +task+
        def handled_exception(error, task)
	    super if defined? super
	    notify_exception(EXCEPTION_HANDLED, error, task)
	end

        def unmark_finished_missions_and_permanent_tasks
            to_unmark = plan.task_index.by_predicate[:finished?] | plan.task_index.by_predicate[:failed?]

            finished_missions = (plan.missions & to_unmark)
	    # Remove all missions that are finished
	    for finished_mission in finished_missions
                if !finished_mission.being_repaired?
                    plan.unmark_mission(finished_mission)
                end
	    end
            finished_permanent = (plan.permanent_tasks & to_unmark)
	    for finished_permanent in (plan.permanent_tasks & to_unmark)
                if !finished_permanent.being_repaired?
                    plan.unmark_permanent(finished_permanent)
                end
	    end
        end
        
        # Kills and removes all unneeded tasks. +force_on+ is a set of task
        # whose garbage-collection must be performed, even though those tasks
        # are actually useful for the system. This is used to properly kill
        # tasks for which errors have been detected.
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
                    raise ArgumentError, "#{mismatching_plan.map(&:to_s).join(", ")} have been given to #garbage_collect, but they are not tasks in #{plan}"
                end
            end

            unmark_finished_missions_and_permanent_tasks

            # The set of tasks for which we queued stop! at this cycle
            # #finishing? is false until the next event propagation cycle
            finishing = ValueSet.new
            did_something = true
            while did_something
                did_something = false

                tasks = plan.unneeded_tasks | plan.force_gc
                local_tasks  = plan.local_tasks & tasks
                remote_tasks = tasks - local_tasks

                # Remote tasks are simply removed, regardless of other concerns
                for t in remote_tasks
                    ExecutionEngine.debug { "GC: removing the remote task #{t}" }
                    plan.garbage(t)
                end

                break if local_tasks.empty?

                debug do
                    debug "#{local_tasks.size} tasks are unneeded in this plan"
                    local_tasks.each do |t|
                        debug "  #{t} mission=#{plan.mission?(t)} permanent=#{plan.permanent?(t)}"
                    end
                    break
                end

                if local_tasks.all? { |t| t.pending? || t.finished? }
                    local_tasks.each do |t|
                        debug { "GC: #{t} is not running, removed" }
                        plan.garbage(t)
                    end
                    break
                end

                # Mark all root local_tasks as garbage.
                roots = nil
                2.times do |i|
                    roots = local_tasks.dup
                    for rel in TaskStructure.relations
                        next if !rel.root_relation?
                        roots.delete_if do |t|
                            t.enum_parent_objects(rel).any? { |p| !p.finished? }
                        end
                        break if roots.empty?
                    end

                    break if i == 1 || !roots.empty?

                    # There is a cycle somewhere. Try to break it by removing
                    # weak relations within elements of local_tasks
                    debug "cycle found, removing weak relations"

                    local_tasks.each do |t|
                        for rel in t.sorted_relations
                            rel.remove(t) if rel.weak?
                        end
                    end
                end

                (roots.to_value_set - finishing - plan.gc_quarantine).each do |local_task|
                    if local_task.pending?
                        info "GC: removing pending task #{local_task}"

                        plan.garbage(local_task)
                        did_something = true
                    elsif local_task.failed_to_start?
                        info "GC: removing task that failed to start #{local_task}"
                        plan.garbage(local_task)
                        did_something = true
                    elsif local_task.starting?
                        # wait for task to be started before killing it
                        debug { "GC: #{local_task} is starting" }
                    elsif local_task.finished?
                        debug { "GC: #{local_task} is not running, removed" }
                        plan.garbage(local_task)
                        did_something = true
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
                plan.garbage(event)
            end
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
            engine = plan.engine
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

        # A list of threads which are currently waitiing for the control thread
        # (see for instance Roby.execute)
        #
        # #run will raise ExecutionQuitError on this threads if they
        # are still waiting while the control is quitting
        attr_reader :waiting_threads

        # A list of threads that are performing work for the benefit of the
        # currently running Roby plan
        #
        # It is there mostly for the benefit of {#join_all_worker_threads}
        # during testing
        attr_reader :worker_threads

        # A set of blocks that are called at each cycle end
        attr_reader :at_cycle_end_handlers

        # Adds a block to be called at the end of each execution cycle
        #
        # @return [Object] an object that allows to identify the block so that
        #   it can be removed with {#remove_at_cycle_end}
        #
        # @yieldparam [Plan] plan the plan on which this engine runs
        def at_cycle_end(&block)
            handler = PollBlockDefinition.new("at_cycle_end #{block}", block, Hash.new)
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
        def every(duration, options = Hash.new, &block)
            handler = PollBlockDefinition.new("periodic handler #{block}", block, options)

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
	def running?; !!@thread end

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
	def run(options = {})
	    if running?
		raise "there is already a control running in thread #{@thread}"
	    end

	    options = validate_options options, :cycle => 0.1

	    @quit = 0
            @allow_propagation = false

            # Start the control thread and wait for @thread to be set
            Roby.condition_variable(true) do |cv, mt|
                mt.synchronize do
                    @thread = Thread.new do
                        @thread = Thread.current
                        @thread.priority = THREAD_PRIORITY

                        begin
                            @cycle_length = options[:cycle]
                            mt.synchronize { cv.signal }
                            event_loop

                        ensure
                            Roby.synchronize do
                                # reset the options only if we are in the control thread
                                @thread = nil
                                waiting_threads.each do |th|
                                    th.raise ExecutionQuitError
                                end
                                finalizers.each { |blk| blk.call rescue nil }
                                @quit = 0
                                @allow_propagation = true
                            end
                        end
                    end
                    while !cycle_length
                        cv.wait(mt)
                    end
                end
            end
	end

	attr_reader :last_stop_count # :nodoc:

        # Sets up the plan for clearing: it discards all missions and undefines
        # all permanent tasks and events.
        #
        # Returns nil if the plan is cleared, and the set of remaining tasks
        # otherwise. Note that quaranteened tasks are not counted as remaining,
        # as it is not possible for the execution engine to stop them.
	def clear
	    Roby.synchronize do
		plan.missions.dup.each { |t| plan.unmark_mission(t) }
		plan.permanent_tasks.dup.each { |t| plan.unmark_permanent(t) }
		plan.permanent_events.dup.each { |t| plan.unmark_permanent(t) }
		plan.force_gc.merge( plan.known_tasks )

		quaranteened_subplan = plan.useful_task_component(nil, ValueSet.new, plan.gc_quarantine.dup)
		remaining = plan.known_tasks - quaranteened_subplan

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
			ExecutionEngine.info "control quitting. Waiting for #{remaining.size} tasks to finish (#{plan.size} tasks still in plan)"
                        remaining.each do |task|
                            ExecutionEngine.info "  #{task}"
                        end
		    else
			ExecutionEngine.info "waiting for #{remaining.size} tasks to finish (#{plan.size} tasks still in plan)"
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
	end

        # How much time remains before the end of the cycle. Updated by
        # #add_timepoint
	attr_reader :remaining_cycle_time

        # Adds to the stats the given duration as the expected duration of the
        # +name+ step. The field in +stats+ is named "expected_<name>".
	def add_expected_duration(stats, name, duration)
	    stats[:"expected_#{name}"] = Time.now + duration - stats[:start]
	end

        # Adds in +stats+ the current time as a timepoint named +time+, and
        # update #remaining_cycle_time
        def add_timepoint(stats, name)
            stats[:end] = stats[name] = Time.now - stats[:start]
            @remaining_cycle_time = cycle_length - stats[:end]
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

	    gc_enable_has_argument = begin
					 GC.enable(true)
					 true
				     rescue
                                         Application.info "GC.enable does not accept an argument. GC will not be controlled by Roby"
                                         false
				     end
	    stats = Hash.new
	    if ObjectSpace.respond_to?(:live_objects)
		last_allocated_objects = ObjectSpace.allocated_objects
	    end
            last_cpu_time = Process.times
            last_cpu_time = (last_cpu_time.utime + last_cpu_time.stime) * 1000

	    GC.start
	    if gc_enable_has_argument
		already_disabled_gc = GC.disable
	    end
	    loop do
		begin
		    if quitting?
			thread.priority = 0
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

		    while Time.now > cycle_start + cycle_length
			@cycle_start += cycle_length
			@cycle_index += 1
		    end
                    stats[:start] = cycle_start
		    stats[:cycle_index] = cycle_index

                    Roby.synchronize do
                        process_events(stats) 
                    end

                    @remaining_cycle_time = cycle_length - stats[:end]
		    
		    # If the ruby interpreter we run on offers a true/false argument to
		    # GC.enable, we disabled the GC and just run GC.enable(true) to make
		    # it run immediately if needed. Then, we re-disable it just after.
		    if gc_enable_has_argument && remaining_cycle_time > SLEEP_MIN_TIME
			GC.enable(true)
			GC.disable
		    end
		    add_timepoint(stats, :ruby_gc)

		    # Sleep if there is enough time for it
		    if remaining_cycle_time > SLEEP_MIN_TIME
			add_expected_duration(stats, :sleep, remaining_cycle_time)
			sleep(remaining_cycle_time) 
		    end
		    add_timepoint(stats, :sleep)

		    # Add some statistics and call cycle_end
		    if defined? Roby::Log
			stats[:log_queue_size] = Roby::Log.logged_events.size
		    end
		    stats[:plan_task_count]  = plan.known_tasks.size
		    stats[:plan_event_count] = plan.free_events.size
		    cpu_time = Process.times
                    cpu_time = (cpu_time.utime + cpu_time.stime) * 1000
		    stats[:cpu_time] = cpu_time - last_cpu_time
                    last_cpu_time = cpu_time

		    if ObjectSpace.respond_to?(:live_objects)
			stats[:object_allocation] = ObjectSpace.allocated_objects - last_allocated_objects
                        stats[:live_objects] = ObjectSpace.live_objects
                        last_allocated_objects = ObjectSpace.allocated_objects
		    end
                    if ObjectSpace.respond_to?(:heap_slots)
                        stats[:heap_slots] = ObjectSpace.heap_slots
                    end

		    stats[:start] = [cycle_start.tv_sec, cycle_start.tv_usec]
                    stats[:state] = Roby::State
                    Roby.synchronize do
                        cycle_end(stats)
                    end
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
		end
	    end

	ensure
	    GC.enable if !already_disabled_gc

	    if !plan.known_tasks.empty?
		ExecutionEngine.warn "the following tasks are still present in the plan:"
		plan.known_tasks.each do |t|
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

	# Called at each cycle end
	def cycle_end(stats)
	    super if defined? super 

	    at_cycle_end_handlers.each do |handler|
		begin
		    handler.call(self)
		rescue Exception => e
		    add_framework_error(e, "during cycle end handler #{handler}")
		end
	    end
	end

	# If the event thread has been started in its own thread, 
	# wait for it to terminate
	def join
	    thread.join if thread

	rescue Interrupt
	    Roby.synchronize do
		return unless thread

		ExecutionEngine.logger.level = Logger::INFO
		ExecutionEngine.warn "received interruption request"
                if quitting?
                    force_quit
                    thread.raise Interrupt, "interrupting control thread at user request"
                else
                    quit
                end
	    end

	    retry
	end

        # Block until the given block is executed by the execution thread, at
        # the beginning of the event loop, in propagation context. If the block
        # raises, the exception is raised back in the calling thread.
        #
        # This cannot be used in the execution thread itself.
        #
        # If no execution thread is present, yields after having taken
        # Roby.global_lock
        def execute
	    if inside_control?
		return Roby.synchronize { yield }
	    end

	    cv = Roby.condition_variable

	    return_value = nil
	    Roby.synchronize do
		if !running?
		    raise ExecutionQuitError, "control thread not running"
		end

		caller_thread = Thread.current
		waiting_threads << caller_thread

                done = false
		once do
		    begin
			return_value = yield
                        done = true
			cv.broadcast
		    rescue Exception => e
			caller_thread.raise e, e.message, e.backtrace
		    end
                    waiting_threads.delete(caller_thread)
		end

                while !done
                    cv.wait(Roby.global_lock)
                end
	    end
	    return_value

	ensure
	    Roby.return_condition_variable(cv)
        end

        # Stops the current thread until the given even is emitted. If the event
        # becomes unreachable, an UnreachableEvent exception is raised.
        def wait_until(ev)
            if inside_control?
                raise ThreadMismatch, "cannot use #wait_until in execution threads"
            end

            Roby.condition_variable(true) do |cv, mt|
                caller_thread = Thread.current
                # Note: no need to add the caller thread in waiting_threads,
                # since the event will become unreachable if the execution
                # thread quits

                mt.synchronize do
                    done = false
                    once do
                        ev.if_unreachable(true) do |reason, event|
                            mt.synchronize do
                                done = true
                                caller_thread.raise UnreachableEvent.new(event, reason)
                            end
                        end
                        ev.on do |ev|
                            mt.synchronize do
                                done = true
                                cv.broadcast
                            end
                        end
                        yield if block_given?
                    end

                    while !done
                        cv.wait(mt)
                    end
                end
            end
        end

        # Kill all tasks that are currently running in the plan
        def killall(limit = 100)
            if scheduler
                scheduler_enabled = scheduler.enabled?
            end

            last_known_tasks = ValueSet.new
            last_quarantine = ValueSet.new
            counter = 0
            loop do
                plan.permanent_tasks.clear
                plan.permanent_events.clear
                plan.missions.clear
                plan.transactions.each do |trsc|
                    trsc.discard_transaction!
                end

                if scheduler
                    scheduler.enabled = false
                end
                quit
                join

                if !running?
                    start_new_cycle
                    process_events
                end

                counter += 1
                if counter > limit
                    Roby.warn "more than #{counter} iterations while trying to shut down #{plan}, quarantine=#{plan.gc_quarantine.size} tasks, tasks=#{plan.known_tasks.size} tasks"
                    if last_known_tasks != plan.known_tasks
                        Roby.warn "Known tasks:"
                        plan.known_tasks.each do |t|
                            Roby.warn "  #{t}"
                        end
                        last_known_tasks = plan.known_tasks.dup
                    end
                    if last_quarantine != plan.gc_quarantine
                        Roby.warn "Quarantined tasks:"
                        plan.gc_quarantine.each do |t|
                            Roby.warn "  #{t}"
                        end
                        last_quarantine = plan.gc_quarantine.dup
                    end
                end
                if plan.gc_quarantine.size == plan.known_tasks.size
                    break
                end
                sleep 0.01
            end
        ensure
            if scheduler
                scheduler.enabled = scheduler_enabled
            end
        end

	EXCEPTION_NONFATAL = :nonfatal
	EXCEPTION_FATAL    = :fatal
	EXCEPTION_HANDLED  = :handled

	# Registers a callback that will be called when exceptions are
	# propagated in the plan
	#
        # @yieldparam [Object] kind one of the EXCEPTION_* constants
        # @yieldparam [Roby::ExecutionException] error the exception
        # @yieldparam [Array<Roby::Task>] tasks the tasks that are being killed
        #   because of this exception
        # @return [Object] an ID that can be used as argument to
	#   {#remove_exception_listener}
	def on_exception(&block)
            handler = PollBlockDefinition.new("exception listener #{block}", block, :on_error => :disable)
	    exception_listeners << handler
	    handler
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
	def notify_exception(kind, error, tasks)
	    exception_listeners.each do |listener|
		listener.call(self, kind, error, tasks)
	    end
	end
    end

    # Execute the given block in the main plan's propagation context, but don't
    # wait for its completion like Roby.execute does
    #
    # See ExecutionEngine#once
    def self.once; engine.once { yield } end

    # Make the main engine call +block+ during each propagation step.
    # See ExecutionEngine#each_cycle
    def self.each_cycle(&block); engine.each_cycle(&block) end

    # Install a periodic handler on the main engine
    def self.every(duration, options = Hash.new, &block); engine.every(duration, options, &block) end

    # True if the current thread is the execution thread of the main engine
    #
    # See ExecutionEngine#inside_control?
    def self.inside_control?; engine.inside_control? end

    # True if the current thread is not the execution thread of the main engine
    #
    # See ExecutionEngine#outside_control?
    def self.outside_control?; engine.outside_control? end

    # Execute the given block during the event propagation step of the main
    # engine. See ExecutionEngine#execute
    def self.execute
        engine.execute do
            yield
        end
    end

    # Blocks until the main engine has executed at least one cycle.
    # See ExecutionEngine#wait_one_cycle
    def self.wait_one_cycle; engine.wait_one_cycle end

    # Stops the current thread until the given even is emitted. If the event
    # becomes unreachable, an UnreachableEvent exception is raised.
    #
    # See ExecutionEngine#wait_until
    def self.wait_until(ev, &block); engine.wait_until(ev, &block) end
end


