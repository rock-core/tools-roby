# This module contains all code necessary for the propagation steps during
# execution. This includes event and exception propagation
#
# == Event propagation
# Event propagation is based on three event relations:
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
# * Precedence is a graph which constrains the order in which propagation is
#   done. If there is a a => b edge in Precedence, and if both events are either
#   called and/or forwarded in the same cycle, then 'a' will be propagated before
#   'b'. All edges in Signal and Forwarding are present in Precedence
#
# == Exception propagation
module Roby
    class ExecutionEngine
        extend Logger::Hierarchy
        extend Logger::Forward

        def initialize(plan)
            @plan = plan
            plan.engine = self
            @propagation_id = 0
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
	    @thread      = nil
	    @cycle_index = 0
	    @cycle_start = Time.now
	    @cycle_length = 0
	    @last_stop_count = 0
            @finalizers = []
	end

        # The plan this engine is acting on
        attr_reader :plan
        # A numeric ID giving the count of the current propagation cycle
        attr_reader :propagation_id
        
        @propagation_handlers = []
        class << self
            attr_reader :propagation_handlers

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
            # This method sets up global propagation handlers (i.e. to be used for
            # all propagation on any plan). For per-plan propagation handlers, see
            # ExecutionEngine#add_propagation_handler.
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
        end

        # A set of block objects that have to be called at the beginning of every
        # propagation phase. These objects are called in propagation context, which
        # means that the events they would call or emit are injected in the
        # propagation process itself.
        attr_reader :propagation_handlers
        
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

        def each_cycle(&block)
            check_arity block, 1
            propagation_handlers << block
        end

        # The scheduler is the object which handles non-generic parts of the
        # propagation cycle.  For now, its #initial_events method is called at
        # the beginning of each propagation cycle and can call or emit a set of
        # events.
        attr_accessor :scheduler

        # If we are currently in the propagation stage
        def gathering?; !!@propagation end
        # The set of source events for the current propagation action. This is a
        # mix of EventGenerator and Event objects.
        attr_reader :propagation_sources
        # The set of events extracted from ExecutionEngine.sources
        def propagation_source_events
            result = ValueSet.new
            for ev in @propagation_sources
                if ev.respond_to?(:generator)
                    result << ev
                end
            end
            result
        end

        # The set of generators extracted from ExecutionEngine.sources
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

        attr_reader :delayed_events
        def add_event_delay(time, forward, source, signalled, context)
            delayed_events << [time, forward, source, signalled, context]
        end
        def execute_delayed_events
            reftime = Time.now
            delayed_events.delete_if do |time, forward, source, signalled, context|
                if time <= reftime
                    add_event_propagation(forward, [source], signalled, context, nil)
                    true
                end
            end
        end

        def finalized_event(event)
            event.unreachable!(nil, plan)
            delayed_events.delete_if { |_, _, _, signalled, _| signalled == event }
        end

        # Begin an event propagation stage
        def gather_propagation(initial_set = Hash.new)
            raise InternalError, "nested call to #gather_propagation" if gathering?
            @propagation = initial_set

            propagation_context(nil) { yield }

            return @propagation
        ensure
            @propagation = nil
        end

        def self.to_execution_exception(error)
            Roby::ExecutionException.new(error)
        end

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

        def gather_framework_errors(source)
            yield
        rescue Exception => e
            add_framework_error(e, source)
        end

        def add_framework_error(error, source)
            if @application_exceptions
                @application_exceptions << [error, source]
            elsif Roby.app.abort_on_application_exception? || error.kind_of?(SignalException)
                raise error, "in #{source}: #{error.message}", error.backtrace
            else
                ExecutionEngine.error "Application error in #{source}: #{error.full_message}"
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

        # Adds a propagation to the next propagation step. More specifically, it
        # adds either forwarding or signalling the set of Event objects +from+ to
        # the +signalled+ event generator, with the context +context+
        def add_event_propagation(forward, from, signalled, context, timespec)
            if signalled.plan != plan
                raise Roby::EventNotExecutable.new(signalled), "#{signalled} not in executed plan"
            end

            step = (@propagation[signalled] ||= [nil, nil])
            from = [nil] unless from && !from.empty?

            step = if forward then (step[0] ||= [])
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

            # Problem with postponed: the object is included in already_seen while it
            # has not been fired
            already_seen = initial_set.to_set

            while !next_step.empty?
                next_step = event_propagation_step(next_step, already_seen)
            end        
            @propagation_exceptions

        ensure
            @propagation_exceptions = nil
        end

        def self.validate_timespec(timespec)
            if timespec
                timespec = validate_options timespec, [:delay, :at]
            end
        end
        def self.make_delay(timeref, source, signalled, timespec)
            if delay = timespec[:delay] then timeref + delay
            elsif at = timespec[:at] then at
            else
                raise ArgumentError, "invalid timespec #{timespec}"
            end
        end

        # The topological ordering of events w.r.t. the Precedence relation
        attr_reader :event_ordering
        # The event => index hash which give the propagation priority for each
        # event
        attr_reader :event_priorities

        # Determines the event in +current_step+ which should be signalled now.
        # Removes it from the set and returns the event and the associated
        # propagation information
        def next_event(pending)
            if event_ordering.empty?
                Roby::EventStructure::Precedence.topological_sort(event_ordering)
                event_priorities.clear
                i = 0
                for ev in event_ordering
                    event_priorities[ev] = i
                    i += 1
                end
            end

            signalled, min = nil, event_ordering.size
            for propagation_step in pending
                event = propagation_step[0]
                if priority = event_priorities[event]
                    if priority < min
                        signalled = event
                        min = priority
                    end
                else
                    signalled = event
                    break
                end
            end
            [signalled, *pending.delete(signalled)]
        end

        def prepare_propagation(signalled, forward, info)
            timeref = Time.now

            source_events, source_generators, context = ValueSet.new, ValueSet.new, []

            delayed = true
            info.each_slice(3) do |src, ctxt, time|
                if time && (delay = ExecutionEngine.make_delay(timeref, src, signalled, time))
                    add_event_delay(delay, forward, src, signalled, ctxt)
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
        # +current_step+ describes all pending emissions and calls. +already_seen+
        # is obsolete and is not used anymore.
        # 
        # This method calls ExecutionEngine.next_event to get the description of the
        # next event to call. If there are signals going to this event, they are
        # processed and the forwardings will be treated in the next step.
        #
        # The method returns the next set of pending emissions and calls, adding
        # the forwardings and signals that the propagation of the considered event
        # have added.
        def event_propagation_step(current_step, already_seen)
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
                                    add_error(e)
                                rescue Exception => e
                                    add_error(Roby::CommandFailed.new(e, signalled))
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

            # Call global exception handlers for exceptions in +fatal+. Return the
            # set of still unhandled exceptions
            fatal.
                find_all { |e| !e.handled? }.
                reject { |e| plan.handle_exception(e) }
        end

        # A set of proc objects which should be executed at the beginning of the
        # next execution cycle.
        attr_reader :process_once

        def once(&block)
            process_once.push block
        end

        # The set of errors which have been generated outside of the plan's
        # control. For those errors, either specific handling must be designed or
        # the whole controller must shut down.
        #
        # The handling of those errors is to be done by the event loop in control
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
            events_errors = propagate_events
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
            kill_tasks = fatal_errors.inject(ValueSet.new) do |kill_tasks, (error, tasks)|
                tasks ||= [*error.task]
                for parent in [*tasks]
                    new_tasks = parent.reverse_generated_subgraph(Roby::TaskStructure::Hierarchy) - plan.force_gc
                    if !new_tasks.empty?
                        fatal_exception(error, new_tasks)
                    end
                    kill_tasks.merge(new_tasks)
                end
                kill_tasks
            end
            add_timepoint(stats, :exceptions_fatal)

            garbage_collect(kill_tasks)
            add_timepoint(stats, :garbage_collect)

            application_errors, @application_exceptions = 
                @application_exceptions, nil
            for error, origin in application_errors
                add_framework_error(error, origin)
            end
            add_timepoint(stats, :application_errors)

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
        
        # Kills and removes all unneeded tasks
        def garbage_collect(force_on = nil)
            if force_on && !force_on.empty?
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
                    remove_object(t)
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
                        next if t.root?
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
                    elsif local_task.finished?
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
                                    ExecutionEngine.debug { "GC: stopping #{local_task}" }
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
        # ExecutionEngine#run will raise ExecutionQuitError on this threads if they
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

        # Call +block+ every +duration+ seconds. Note that +duration+ is
        # round up to the cycle size (time between calls is *at least* duration)
        def every(duration, &block)
            once do
                block.call
                process_every << [block, cycle_start, duration]
            end
            block.object_id
        end

        def remove_periodic_handler(id)
            execute do
                process_every.delete_if { |spec| spec[0].object_id == id }
            end
        end

	attr_accessor :thread
	def running?; !!@thread end

	# The cycle length in seconds
	attr_reader :cycle_length

	# The starting point of this cycle
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
	# drb:: address of the DRuby server if one should be started (default: nil)
	def run(options = {})
	    if running?
		raise "there is already a control running in thread #{@thread}"
	    end

	    options = validate_options options, :cycle => 0.1

	    @quit = 0

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
                            end
                        end
                    end
                    cv.wait(mt)
                end
            end
	end

	attr_reader :last_stop_count
	def clear
	    Roby.synchronize do
		plan.missions.dup.each { |t| plan.discard(t) }
		plan.permanent_tasks.dup.each { |t| plan.auto(t) }
		plan.permanent_events.dup.each { |t| plan.auto(t) }
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
			ExecutionEngine.debug "  " + remaining.to_a.join("\n  ")
		    else
			ExecutionEngine.info "waiting for #{remaining.size} tasks to finish (#{plan.size} tasks still in plan)"
			ExecutionEngine.debug "  #{remaining.to_a.join("\n  ")}"
		    end
		    if plan.gc_quarantine.size != 0
			ExecutionEngine.info "#{plan.gc_quarantine.size} tasks in quarantine"
		    end
		    @last_stop_count = remaining.size
		end
		remaining
	    end
	end

	attr_reader :remaining_cycle_time
	def add_expected_duration(stats, name, duration)
	    stats[:"expected_#{name}"] = Time.now + duration - cycle_start
	end

        def add_timepoint(stats, name)
            stats[:end] = stats[name] = Time.now - stats[:start]
            @remaining_cycle_time = cycle_length - stats[:end]
        end

	def event_loop
	    @last_stop_count = 0
	    @cycle_start  = Time.now
	    @cycle_index  = 0

	    gc_enable_has_argument = begin
					 GC.enable(true)
					 true
				     rescue
                                         ExecutionEngine.warn "GC.enable does not accept an argument. GC will not be controlled by Roby"
                                         false
				     end
	    stats = Hash.new
	    if ObjectSpace.respond_to?(:live_objects)
		stats[:live_objects] = ObjectSpace.live_objects
	    end

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
		    
		    # Record the statistics about object allocation *before* running the Ruby
		    # GC. It is also updated at 
		    if ObjectSpace.respond_to?(:live_objects)
			live_objects_before_gc = ObjectSpace.live_objects
		    end

		    # If the ruby interpreter we run on offers a true/false argument to
		    # GC.enable, we disabled the GC and just run GC.enable(true) to make
		    # it run immediately if needed. Then, we re-disable it just after.
		    if gc_enable_has_argument && remaining_cycle_time > SLEEP_MIN_TIME
			GC.enable(true)
			GC.disable
		    end
		    add_timepoint(stats, :ruby_gc)

		    if ObjectSpace.respond_to?(:live_objects)
			live_objects_after_gc = ObjectSpace.live_objects
		    end
		    
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
		    process_time = Process.times
		    stats[:cpu_time] = (process_time.utime + process_time.stime) * 1000

		    if ObjectSpace.respond_to?(:live_objects)
			live_objects = ObjectSpace.live_objects
			stats[:object_allocation] = live_objects - stats[:live_objects] - (live_objects_after_gc - live_objects_before_gc)
			stats[:live_objects]      = live_objects
		    end

		    stats[:start]       = [cycle_start.tv_sec, cycle_start.tv_usec]
		    cycle_end(stats)

		    stats = Hash.new
		    stats[:live_objects] = live_objects
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

	def finalizers; @finalizers end

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


