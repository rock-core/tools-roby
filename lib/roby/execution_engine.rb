module Roby
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
    # main execution engine (Roby.engine). One can for instance do
    #   Roby.once { puts "start of the execution thread" }
    #
    # Instead of
    #   Roby.engine.once { ... }
    #
    # Or 
    #   engine.once { ... }
    #
    # Nonetheless, note that it breaks the object-orientation of the system and
    # therefore won't work in cases where you want multiple execution engine to
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
    #   cycle, the command will be called only once
    # * Forwarding describes the events that must be emitted whenever a source
    #   event is. It is to be used as a way to define event aliases (for instance
    #   'stop' is an alias for 'success'), because a task is stopped when it has
    #   finished with success. Unlike with signals, if more than one event is
    #   forwarded to the same event in the same cycle, the target event will be
    #   emitted as many times as the incoming events.
    # * the Precedence relation is a subset of the two preceding relations. It
    #   represents a partial ordering of the events that must be maintained during
    #   the propagation stage (i.e. a notion of causality).
    #
    # In the code, the followin procedure is followed: when a code fragment calls
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
        extend Logger::Forward

        # Create an execution engine acting on +plan+, using +control+ as the
        # decision control object
        #
        # See Roby::Plan and Roby::DecisionControl
        def initialize(plan, control)
            @plan = plan
            plan.engine = self
            @control = control

            @propagation = nil
            @propagation_id = 0
            @propagation_exceptions = nil
            @application_exceptions = nil
            @delayed_events = []
            @process_once = Queue.new
            @event_ordering = Array.new
            @event_priorities = Hash.new
            @propagation_handlers = []
            @at_cycle_end_handlers = Array.new
            @process_every   = Array.new
            @waiting_threads = Array.new

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
        
        @propagation_handlers = []
        class << self
            # Code blocks that get called at the beginning of each cycle. See
            # #add_propagation_handler
            attr_reader :propagation_handlers

            # call-seq:
            #   ExecutionEngine.add_propagation_handler { |plan| ... }
            #
            # The propagation handlers are a set of block objects that have to be
            # called at the beginning of every propagation phase for all plans.
            # These objects are called in propagation context, which means that the
            # events they would call or emit are injected in the propagation
            # process itself.
            #
            # This method adds a new propagation handler. In its first form, the
            # argument is the proc object to be added. In the second form, the
            # block is taken the handler. In both cases, the method returns a value
            # which can be used to remove the propagation handler later. In both
            # cases, the block or proc is called with the plan to propagate on
            # as argument.
            #
            # This method sets up global propagation handlers (i.e. to be used for
            # all propagation on all plans). For per-plan propagation handlers, see
            # ExecutionEngine#add_propagation_handler.
            #
            # See also ExecutionEngine.remove_propagation_handler
            def add_propagation_handler(proc_obj = nil, &block)
                proc_obj ||= block
                check_arity proc_obj, 1
                propagation_handlers << proc_obj
                proc_obj.object_id
            end
            
            # This method removes a propagation handler which has been added by
            # ExecutionEngine.add_propagation_handler.  THe +id+ value is the
            # value returned by ExecutionEngine.add_propagation_handler.
            def remove_propagation_handler(id)
                propagation_handlers.delete_if { |p| p.object_id == id }
                nil
            end
        end

        # A set of block objects that have to be called at the beginning of every
        # propagation phase. These objects are called in propagation context, which
        # means that the events they would call or emit are injected in the
        # propagation process itself.
        attr_reader :propagation_handlers
        
        # call-seq:
        #   engine.add_propagation_handler { |plan| ... }
        #
        # The propagation handlers are a set of block objects that have to be
        # called at the beginning of every propagation phase for all plans.
        # These objects are called in propagation context, which means that the
        # events they would call or emit are injected in the propagation
        # process itself.
        #
        # This method adds a new propagation handler. In its first form, the
        # argument is the proc object to be added. In the second form, the
        # block is taken the handler. In both cases, the method returns a value
        # which can be used to remove the propagation handler later.
        #
        # See also #remove_propagation_handler
        def add_propagation_handler(proc_obj = nil, &block)
            proc_obj ||= block
            check_arity proc_obj, 1
            propagation_handlers << proc_obj
            proc_obj.object_id
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
            propagation_handlers.delete_if { |p| p.object_id == id }
            nil
        end

        # call-seq:
        #   Roby.each_cycle { |plan| ... }
        #
        # Execute the given block at the beginning of each cycle, in propagation
        # context.
        #
        # The returned value is an ID that can be used to remove the handler using
        # #remove_propagation_handler
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

        # Called by #plan when an event has been finalized
        def finalized_event(event)
            event.unreachable!(nil, plan)
            delayed_events.delete_if { |_, _, _, signalled, _| signalled == event }
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
            @propagation = initial_set

            propagation_context(nil) { yield }

            return @propagation
        ensure
            @propagation = nil
        end

        # Converts the Exception object +error+ into a Roby::ExecutionException
        def self.to_execution_exception(error)
            if error.kind_of?(Roby::ExecutionException)
                error
            else
                Roby::ExecutionException.new(error)
            end
        end

        # If called in execution context, adds the plan-based error +e+ to be
        # handled later in the execution cycle. Otherwise, calls
        # #add_framework_error
        def add_error(e)
            if @propagation_exceptions
                plan_exception = ExecutionEngine.to_execution_exception(e)
                @propagation_exceptions << plan_exception
            else
                if e.respond_to?(:error) && e.error
                    add_framework_error(e.error, "error outside error handling")
                else
                    add_framework_error(e, "error outside error handling")
                end
            end
        end

        # Yields to the block, calling #add_framework_error if an exception is
        # raised 
        def gather_framework_errors(source)
            yield
        rescue Exception => e
            add_framework_error(e, source)
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
                current_sources = sources
                @propagation_sources = sources
            else
                @propagation_sources = []
            end

            yield @propagation

        ensure
            @propagation_sources = sources
        end

        def has_propagation_for?(target)
            @propagation && @propagation.has_key?(target)
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

            step = (@propagation[target] ||= [nil, nil])
            from = [nil] unless from && !from.empty?

            step = if is_forward then (step[0] ||= [])
                   else (step[1] ||= [])
                   end

            from.each do |ev|
                step << ev << context << timespec
            end
        end

        # Calls its block in a #gather_propagation context and propagate events
        # that have been called and/or emitted by the block
        #
        # If a block is given, it is called with the initial set of events: the
        # events we should consider as already emitted in the following propagation.
        # +seeds+ si a list of procs which should be called to initiate the propagation
        # (i.e. build an initial set of events)
        def propagate_events(seeds = nil)
            if @propagation_exceptions
                raise InternalError, "recursive call to propagate_events"
            end

            @propagation_id = (@propagation_id += 1)
            @propagation_exceptions = []

            initial_set = []
            next_step = gather_propagation do
                gather_framework_errors('initial set setup')  { yield(initial_set) } if block_given?
                gather_framework_errors('distributed events') { Roby::Distributed.process_pending }
                gather_framework_errors('delayed events')     { execute_delayed_events }
                while !process_once.empty?
                    p = process_once.pop
                    gather_framework_errors("'once' block #{p}") { p.call }
                end
                if seeds
                    for s in seeds
                        gather_framework_errors("seed #{s}") { s.call }
                    end
                end
                if scheduler
                    gather_framework_errors('scheduler')          { scheduler.initial_events }
                end
                for h in self.class.propagation_handlers
                    gather_framework_errors("propagation handler #{h}") { h.call(plan) }
                end
                for h in propagation_handlers
                    gather_framework_errors("propagation handler #{h}") { h.call(plan) }
                end
            end

            while !next_step.empty?
                next_step = event_propagation_step(next_step)
            end        
            @propagation_exceptions

        ensure
            @propagation_exceptions = nil
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
            priority, selected_event = nil
            for propagation_step in pending
                target_event = propagation_step[0]
                forwards, signals = *propagation_step[1]
                target_priority = if forwards && signals then 1
                                  elsif signals then 0
                                  else 2
                                  end

                do_select = if selected_event
                                if EventStructure::Precedence.reachable?(selected_event, target_event)
                                    false
                                elsif EventStructure::Precedence.reachable?(target_event, selected_event)
                                    true
                                else
                                    priority < target_priority
                                end
                            else
                                true
                            end

                if do_select
                    selected_event = target_event
                    priority       = target_priority
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
            signalled, forward_info, call_info = next_event(current_step)

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
                                rescue Roby::LocalizedError => e
                                    signalled.emit_failed(e)
                                rescue Exception => e
                                    signalled.emit_failed(Roby::CommandFailed.new(e, signalled))
                                end
                            end
                        end
                    end
                end

                if forward_info
                    next_step ||= Hash.new
                    next_step[signalled] ||= []
                    next_step[signalled][0] ||= []
                    next_step[signalled][0].concat forward_info
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
                                    signalled.emit_without_propagation(context)
                                rescue Roby::LocalizedError => e
                                    add_error(e)
                                rescue Exception => e
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

        # Checks if +error+ is being repaired in the corresponding plan. Note that
        # +error+ is supposed to be the original exception, not the corresponding
        # ExecutionException object
        def remove_inhibited_exceptions(exceptions)
            exceptions.find_all do |e, _|
                error = e.exception
                if !error.respond_to?(:failed_event) ||
                    !(failure_point = error.failed_event)
                    true
                else
                    plan.repairs_for(failure_point).empty?
                end
            end
        end

        # Removes the set of repairs defined on #plan that are not useful
        # anymore, and returns it.
        def remove_useless_repairs
            finished_repairs = plan.repairs.dup.delete_if { |_, task| task.starting? || task.running? }
            for repair in finished_repairs
                plan.remove_repair(repair[1])
            end

            finished_repairs
        end

        # Performs exception propagation for the given ExecutionException objects
        # Returns all exceptions which have found no handlers in the task hierarchy
        def propagate_exceptions(exceptions)
            fatal   = [] # the list of exceptions for which no handler has been found

            # Remove finished repairs. Those are still considered during this cycle,
            # as it is possible that some actions have been scheduled for the
            # beginning of the next cycle through #once
            finished_repairs = remove_useless_repairs
            # Remove remove exceptions for which a repair exists
            exceptions = remove_inhibited_exceptions(exceptions)

            # Install new repairs based on the HandledBy task relation. If a repair
            # is installed, remove the exception from the set of errors to handle
            exceptions.delete_if do |e, _|
                # Check for handled_by relations which would be able to handle +e+
                error = e.exception
                next unless (failed_event = error.failed_event)
                next unless (failed_task = error.failed_task)
                next if finished_repairs.has_key?(failed_event)

                failed_generator = error.failed_generator

                repair = failed_task.find_error_handler do |repairing_task, event_set|
                    event_set.find do |repaired_generator|
                        repaired_generator = failed_task.event(repaired_generator)

                        !repairing_task.finished? &&
                            (repaired_generator == failed_generator ||
                            Roby::EventStructure::Forwarding.reachable?(failed_generator, repaired_generator))
                    end
                end

                if repair
                    plan.add_repair(failed_event, repair)
                    if repair.pending?
                        once { repair.start! }
                    end
                    true
                else
                    false
                end
            end

            while !exceptions.empty?
                by_task = Hash.new { |h, k| h[k] = Array.new }
                by_task = exceptions.inject(by_task) do |by_task, (e, parents)|
                    unless e.task
                        Roby.log_exception(e.exception, Roby, :fatal)
                        raise NotImplementedError, "we do not yet handle exceptions from external event generators. Got #{e.exception.full_message}"
                    end
                    parents ||= e.task.parent_objects(Roby::TaskStructure::Hierarchy)

                    has_parent = false
                    [*parents].each do |parent|
                        next if parent.finished?

                        if has_parent # we have more than one parent
                            e = e.fork
                        end

                        parent_exceptions = by_task[parent] 
                        if s = parent_exceptions.find { |s| s.siblings.include?(e) }
                            s.merge(e)
                        else parent_exceptions << e
                        end

                        has_parent = true
                    end

                    # Add unhandled exceptions to the fatal set. Merge siblings
                    # exceptions if possible
                    unless has_parent
                        if s = fatal.find { |s| s.siblings.include?(e) }
                            s.merge(e)
                        else fatal << e
                        end
                    end

                    by_task
                end

                parent_trees = by_task.map do |task, _|
                    [task, task.reverse_generated_subgraph(Roby::TaskStructure::Hierarchy)]
                end

                # Handle the exception in all tasks that are in no other parent trees
                new_exceptions = ValueSet.new
                by_task.each do |task, task_exceptions|
                    if parent_trees.find { |t, tree| t != task && tree.include?(task) }
                        task_exceptions.each { |e| new_exceptions << [e, [task]] }
                        next
                    end

                    task_exceptions.each do |e|
                        next if e.handled?
                        handled = task.handle_exception(e)

                        if handled
                            handled_exception(e, task)
                            e.handled = true
                        else
                            # We do not have the framework to handle concurrent repairs
                            # For now, the first handler is the one ... 
                            new_exceptions << e
                            e.trace << task
                        end
                    end
                end

                exceptions = new_exceptions
            end

            if !fatal.empty?
                Roby::ExecutionEngine.debug do
                    "remaining fatal exceptions: #{fatal.map(&:exception).map(&:to_s).join(", ")}"
                end
            end
            # Call global exception handlers for exceptions in +fatal+. Return the
            # set of still unhandled exceptions
            fatal.
                find_all { |e| !e.handled? }.
                reject { |e| plan.handle_exception(e) }
        end

        # A set of proc objects which should be executed at the beginning of the
        # next execution cycle.
        attr_reader :process_once

        # Schedules +block+ to be called at the beginning of the next execution
        # cycle, in propagation context.
        def once(&block)
            process_once.push block
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
                raise Aborting.new(exceptions)
            end
        end
        
        # Process the pending events. The time at each event loop step
        # is saved into +stats+.
        def process_events(stats = {:start => Time.now})
            @application_exceptions = []

            add_timepoint(stats, :real_start)

            # Gather new events and propagate them
            events_errors = begin 
                                old_allow_propagation, @allow_propagation = @allow_propagation, true
                                propagate_events
                            ensure @allow_propagation = old_allow_propagation
                            end
            add_timepoint(stats, :events)

            # HACK: events_errors is sometime nil here. It shouldn't
            events_errors ||= []

            # Generate exceptions from task structure
            structure_errors = plan.check_structure
            add_timepoint(stats, :structure_check)

            # Propagate the errors. Note that the plan repairs are taken into
            # account in ExecutionEngine.propagate_exceptions drectly.  We keep
            # event and structure errors separate since in the first case there
            # is not two-stage handling (all errors that have not been handled
            # are fatal), and in the second case we call #check_structure
            # again to get the remaining errors
            events_errors    = propagate_exceptions(events_errors)
            propagate_exceptions(structure_errors)
            add_timepoint(stats, :exception_propagation)

            # Get the remaining problems in the plan structure, and act on it
            fatal_structure_errors = remove_inhibited_exceptions(plan.check_structure)
            fatal_errors = fatal_structure_errors.to_a + events_errors
            if !fatal_errors.empty?
                Roby::ExecutionEngine.info "EE: #{fatal_errors.size} fatal exceptions remaining"
                kill_tasks = fatal_errors.inject(ValueSet.new) do |kill_tasks, (error, tasks)|
                    tasks ||= [*error.origin]
                    for parent in [*tasks]
                        new_tasks = parent.reverse_generated_subgraph(Roby::TaskStructure::Hierarchy) - plan.force_gc
                        if !new_tasks.empty?
                            fatal_exception(error, new_tasks)
                        end
                        kill_tasks.merge(new_tasks)
                    end
                    kill_tasks
                end
                if !kill_tasks.empty?
                    Roby::ExecutionEngine.info do
                        Roby::ExecutionEngine.info "EE: will kill the following tasks because of unhandled exceptions:"
                        kill_tasks.each do |task|
                            Roby::ExecutionEngine.info "  " + task.to_s
                        end
                        ""
                    end
                end
            end
            add_timepoint(stats, :exceptions_fatal)

            garbage_collect(kill_tasks)
            add_timepoint(stats, :garbage_collect)

            application_errors, @application_exceptions = 
                @application_exceptions, nil
            for error, origin in application_errors
                add_framework_error(error, origin)
            end

            if Roby.app.abort_on_exception? && !fatal_errors.empty?
                reraise(fatal_errors.map { |e, _| e })
            end

        ensure
            @application_exceptions = nil
        end

        # Hook called when a set of tasks is being killed because of an exception
        def fatal_exception(error, tasks)
            super if defined? super
            Roby.format_exception(error.exception).each do |line|
                ExecutionEngine.warn line
            end
        end

        # Hook called when an exception +e+ has been handled by +task+
        def handled_exception(e, task); super if defined? super end
        
        # Kills and removes all unneeded tasks. +force_on+ is a set of task
        # whose garbage-collection must be performed, even though those tasks
        # are actually useful for the system. This is used to properly kill
        # tasks for which errors have been detected.
        def garbage_collect(force_on = nil)
            if force_on && !force_on.empty?
                ExecutionEngine.info "GC: adding #{force_on.size} tasks in the force_gc set"
                plan.force_gc.merge(force_on.to_value_set)
            end

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
                    plan.remove_object(t)
                end

                break if local_tasks.empty?

                if local_tasks.all? { |t| t.pending? || t.finished? }
                    local_tasks.each do |t|
                        ExecutionEngine.debug { "GC: #{t} is not running, removed" }
                        plan.garbage(t)
                        plan.remove_object(t)
                    end
                    break
                end

                # Mark all root local_tasks as garbage
                roots = nil
                2.times do |i|
                    roots = local_tasks.find_all do |t|
                        if t.root?
                            plan.garbage(t)
                            true
                        else
                            ExecutionEngine.debug { "GC: ignoring #{t}, it is not root" }
                            false
                        end
                    end

                    break if i == 1 || !roots.empty?

                    # There is a cycle somewhere. Try to break it by removing
                    # weak relations within elements of local_tasks
                    ExecutionEngine.debug "cycle found, removing weak relations"

                    local_tasks.each do |t|
                        t.each_graph do |rel|
                            rel.remove(t) if rel.weak?
                        end
                    end
                end

                (roots.to_value_set - finishing - plan.gc_quarantine).each do |local_task|
                    if local_task.pending? 
                        ExecutionEngine.info "GC: removing pending task #{local_task}"
                        plan.remove_object(local_task)
                        did_something = true
                    elsif local_task.starting?
                        # wait for task to be started before killing it
                        ExecutionEngine.debug { "GC: #{local_task} is starting" }
                    elsif !local_task.running?
                        ExecutionEngine.debug { "GC: #{local_task} is not running, removed" }
                        plan.remove_object(local_task)
                        did_something = true
                    elsif !local_task.finishing?
                        if local_task.event(:stop).controlable?
                            ExecutionEngine.debug { "GC: queueing #{local_task}/stop" }
                            if !local_task.respond_to?(:stop!)
                                ExecutionEngine.fatal "something fishy: #{local_task}/stop is controlable but there is no #stop! method"
                                plan.gc_quarantine << local_task
                            else
                                finishing << local_task
                                once do
                                    ExecutionEngine.info { "GC: stopping #{local_task}" }
                                    local_task.stop!(nil)
                                end
                            end
                        else
                            ExecutionEngine.warn "GC: ignored #{local_task}, it cannot be stopped"
                            plan.gc_quarantine << local_task
                        end
                    elsif local_task.finishing?
                        ExecutionEngine.debug { "GC: waiting for #{local_task} to finish" }
                    else
                        ExecutionEngine.warn "GC: ignored #{local_task}"
                    end
                end
            end

            plan.unneeded_events.each do |event|
                plan.remove_object(event)
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
                begin
                    # Check if the nearest timepoint is the beginning of
                    # this cycle or of the next cycle
                    if !last_call || (duration - (now - last_call)) < length / 2
                        block.call
                        last_call = now
                    end
                rescue Exception => e
                    engine.add_framework_error(e, "#call_every, in #{block}")
                end
                [block, last_call, duration]
            end
        end

        # A list of threads which are currently waitiing for the control thread
        # (see for instance Roby.execute)
        #
        # #run will raise ExecutionQuitError on this threads if they
        # are still waiting while the control is quitting
        attr_reader :waiting_threads

        # A set of blocks that are called at each cycle end
        attr_reader :at_cycle_end_handlers

        # Call +block+ at the end of the execution cycle	
        def at_cycle_end(&block)
            at_cycle_end_handlers << block
        end

        # A set of blocks which are called every cycle
        attr_reader :process_every

        # Call +block+ every +duration+ seconds. Note that +duration+ is round
        # up to the cycle size (time between calls is *at least* duration)
        #
        # The returned value is the periodic handler ID. It can be passed to
        # #remove_periodic_handler to undefine it.
        def every(duration, &block)
            once do
                block.call
                process_every << [block, cycle_start, duration]
            end
            block.object_id
        end

        # Removes a periodic handler defined by #every. +id+ is the value
        # returned by #every.
        def remove_periodic_handler(id)
            execute do
                process_every.delete_if { |spec| spec[0].object_id == id }
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
                            mt.synchronize { cv.signal }
                            @cycle_length = options[:cycle]
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
                    cv.wait(mt)
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
		    return
		end

		if last_stop_count != remaining.size
		    if last_stop_count == 0
			ExecutionEngine.info "control quitting. Waiting for #{remaining.size} tasks to finish (#{plan.size} tasks still in plan)"
			ExecutionEngine.info "  " + remaining.to_a.join("\n  ")
		    else
			ExecutionEngine.info "waiting for #{remaining.size} tasks to finish (#{plan.size} tasks still in plan)"
			ExecutionEngine.info "  #{remaining.to_a.join("\n  ")}"
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
        # +name+ step. The field in +stats+ is named "expected_#{name}".
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
                                         if gc_warning?
                                             ExecutionEngine.warn "GC.enable does not accept an argument. GC will not be controlled by Roby"
                                         end
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
		    cycle_end(stats)
                    stats = Hash.new

		    @cycle_start += cycle_length
		    @cycle_index += 1

		rescue Exception => e
		    ExecutionEngine.warn "Execution thread quitting because of unhandled exception"
                    Roby.format_exception(e).each do |line|
                        ExecutionEngine.warn line
                    end
		    quit
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

        # A set of proc objects which are to be called when the execution engine
        # quits.
        attr_reader :finalizers

	# True if the control thread is currently quitting
	def quitting?; @quit > 0 end
	# True if the control thread is currently quitting
	def forced_exit?; @quit > 1 end
	# Make control quit
	def quit; @quit += 1 end

	# Called at each cycle end
	def cycle_end(stats)
	    super if defined? super 

	    at_cycle_end_handlers.each do |handler|
		begin
		    handler.call
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
		quit
		if @quit > 2
		    thread.raise Interrupt, "interrupting control thread at user request"
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
		    raise "control thread not running"
		end

		caller_thread = Thread.current
		waiting_threads << caller_thread

		once do
		    begin
			return_value = yield
			cv.broadcast
		    rescue Exception => e
			caller_thread.raise e, e.message, e.backtrace
		    end
                    waiting_threads.delete(caller_thread)
		end
		cv.wait(Roby.global_lock)
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
                    once do
                        ev.if_unreachable(true) do |reason|
                            caller_thread.raise UnreachableEvent.new(ev, reason)
                        end
                        ev.on do
                            mt.synchronize { cv.broadcast }
                        end
                        yield
                    end
                    cv.wait(mt)
                end
            end
        end
    end

    class << self
        # The ExecutionEngine object which executes Roby.plan
        attr_reader :engine

        # Sets the engine. This can be done only once
        def engine=(new_engine)
            if engine
                raise ArgumentError, "cannot change the execution engine"
            elsif plan && plan.engine && plan.engine != new_engine
                raise ArgumentError, "must have Roby.engine == Roby.plan.engine"
            elsif control && new_engine.control != control
                raise ArgumentError, "must have Roby.control == Roby.engine.control"
            end

            @engine  = new_engine
            @control = new_engine.control
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
    def self.every(duration, &block); engine.every(duration, &block) end

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
    def self.wait_until(ev); engine.wait_until(ev) end
end


