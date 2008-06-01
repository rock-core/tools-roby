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
module Roby::Propagation
    extend Logger::Hierarchy
    extend Logger::Forward

    def initialize(*args)
        @exception_handlers = Array.new
        @propagation_id = 0
        @delayed_events = []
	@process_once = Queue.new
        @event_ordering = Array.new
        @event_priorities = Hash.new
        @propagation_engine   = self
        @propagation_handlers = []
        super
    end

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
        # Propagation#add_propagation_handler.
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
    def self.each_cycle(&block)
        Roby.plan.each_cycle(&block)
    end

    # An executive object, which would handle parts of the propagation cycle.
    # For now, its #initial_events method is called at the beginning of each
    # propagation cycle and can call or emit a set of events.
    attr_accessor :scheduler

    # If we are currently in the propagation stage
    def gathering?; !!@propagation end
    # The set of source events for the current propagation action. This is a
    # mix of EventGenerator and Event objects.
    attr_reader :propagation_sources
    # The set of events extracted from PropagationException.sources
    def propagation_source_events
	result = ValueSet.new
	for ev in @propagation_sources
	    if ev.respond_to?(:generator)
		result << ev
	    end
	end
	result
    end

    # The set of generators extracted from Propagation.sources
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
        super if defined? super
        event.unreachable!(nil, self)
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
	    plan_exception = Roby::Propagation.to_execution_exception(e)
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
	    Roby.error "Application error in #{source}: #{error.full_message}"
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
	if signalled.plan != self
	    raise Roby::EventNotExecutable.new(signalled), "#{signalled} not in main plan"
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
            for h in Roby::Propagation.propagation_handlers
                gather_framework_errors("propagation handler #{h}") { h.call(self) }
            end
            for h in propagation_handlers
                gather_framework_errors("propagation handler #{h}") { h.call(self) }
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

    # Hooks which clear the event ordering cache (Propagation.event_ordering)
    # when needed.
    def discovered_events(objects)
        super if defined? super
        event_ordering.clear
    end
    def discovered_tasks(objects)
        super if defined? super
        event_ordering.clear
    end
    
    # This module hooks in event relation modifications to clear the event
    # ordering cache (Propagation.event_ordering) when needed.
    module EventPrecedenceChanged
	def added_child_object(child, relations, info)
	    super if defined? super
	    if relations.include?(Roby::EventStructure::Precedence) && plan.respond_to?(:event_ordering)
		plan.event_ordering.clear
	    end
	end
	def removed_child_object(child, relations)
	    super if defined? super
	    if relations.include?(Roby::EventStructure::Precedence) && plan.respond_to?(:event_ordering)
		plan.event_ordering.clear
	    end
	end
    end
    Roby::EventGenerator.include EventPrecedenceChanged

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
	    if time && (delay = Roby::Propagation.make_delay(timeref, src, signalled, time))
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
    # This method calls Propagation.next_event to get the description of the
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
		repairs_for(failure_point).empty?
	    end
	end
    end

    def remove_useless_repairs
	finished_repairs = repairs.dup.delete_if { |_, task| task.starting? || task.running? }
	for repair in finished_repairs
	    remove_repair(repair[1])
	end

	finished_repairs
    end

    # Performs exception propagation for the given ExecutionException objects
    # Returns all exceptions which have found no handlers in the task hierarchy
    def propagate_exceptions(exceptions)
	fatal   = [] # the list of exceptions for which no handler has been found

	# Remove finished repairs. Those are still considered during this cycle,
        # as it is possible that some actions have been scheduled for the
        # beginning of the next cycle through Roby.once
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
		add_repair(failed_event, repair)
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
	    reject { |e| handle_exception(e) }
    end

    # A set of proc objects which should be executed at the beginning of the
    # next execution cycle.
    attr_reader :process_once

    def once(&block)
        process_once.push block
    end

    attr_reader :exception_handlers
    def each_exception_handler(&iterator); exception_handlers.each(&iterator) end
    # define_method(:each_exception_handler, &Roby::Propagation.exception_handlers.method(:each))
    def on_exception(*matchers, &handler)
        check_arity(handler, 2)
        exception_handlers.unshift [matchers, handler]
    end

    include Roby::ExceptionHandlingObject

    def self.add_timepoint(stats, name)
        stats[:end] = stats[name] = Time.now - stats[:start]
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

        Roby::Propagation.add_timepoint(stats, :real_start)

        # Gather new events and propagate them
        events_errors = propagate_events
        Roby::Propagation.add_timepoint(stats, :events)

        # HACK: events_errors is sometime nil here. It shouldn't
        events_errors ||= []

        # Generate exceptions from task structure
        structure_errors = check_structure
        Roby::Propagation.add_timepoint(stats, :structure_check)

        # Propagate the errors. Note that the plan repairs are taken into
        # account in Propagation.propagate_exceptions drectly.  We keep
        # event and structure errors separate since in the first case there
        # is not two-stage handling (all errors that have not been handled
        # are fatal), and in the second case we call #check_structure
        # again to get the remaining errors
        events_errors    = propagate_exceptions(events_errors)
        propagate_exceptions(structure_errors)
        Roby::Propagation.add_timepoint(stats, :exception_propagation)

        # Get the remaining problems in the plan structure, and act on it
        fatal_structure_errors = remove_inhibited_exceptions(check_structure)
        fatal_errors = fatal_structure_errors.to_a + events_errors
        kill_tasks = fatal_errors.inject(ValueSet.new) do |kill_tasks, (error, tasks)|
            tasks ||= [*error.task]
            for parent in [*tasks]
                new_tasks = parent.reverse_generated_subgraph(Roby::TaskStructure::Hierarchy) - force_gc
                if !new_tasks.empty?
                    fatal_exception(error, new_tasks)
                end
                kill_tasks.merge(new_tasks)
            end
            kill_tasks
        end
        Roby::Propagation.add_timepoint(stats, :exceptions_fatal)

        garbage_collect(kill_tasks)
        Roby::Propagation.add_timepoint(stats, :garbage_collect)

        application_errors, @application_exceptions = 
            @application_exceptions, nil
        for error, origin in application_errors
            add_framework_error(error, origin)
        end
        Roby::Propagation.add_timepoint(stats, :application_errors)

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
            Roby.warn line
        end
    end

    # Hook called when an exception +e+ has been handled by +task+
    def handled_exception(e, task); super if defined? super end
    
	# Kills and removes all unneeded tasks
	def garbage_collect(force_on = nil)
	    if force_on && !force_on.empty?
		force_gc.merge(force_on.to_value_set)
	    end

	    # The set of tasks for which we queued stop! at this cycle
	    # #finishing? is false until the next event propagation cycle
	    finishing = ValueSet.new
	    did_something = true
	    while did_something
		did_something = false

		tasks = unneeded_tasks | force_gc
		local_tasks  = self.local_tasks & tasks
		remote_tasks = tasks - local_tasks

		# Remote tasks are simply removed, regardless of other concerns
		for t in remote_tasks
		    Roby::Propagation.debug { "GC: removing the remote task #{t}" }
		    remove_object(t)
		end

		break if local_tasks.empty?

		if local_tasks.all? { |t| t.pending? || t.finished? }
		    local_tasks.each do |t|
			Roby::Propagation.debug { "GC: #{t} is not running, removed" }
			garbage(t)
			remove_object(t)
		    end
		    break
		end

		# Mark all root local_tasks as garbage
		roots = nil
		2.times do |i|
		    roots = local_tasks.find_all do |t|
			if t.root?
			    garbage(t)
			    true
			else
			    Roby::Propagation.debug { "GC: ignoring #{t}, it is not root" }
			    false
			end
		    end

		    break if i == 1 || !roots.empty?

		    # There is a cycle somewhere. Try to break it by removing
		    # weak relations within elements of local_tasks
		    Roby::Propagation.debug "cycle found, removing weak relations"

		    local_tasks.each do |t|
			next if t.root?
			t.each_graph do |rel|
			    rel.remove(t) if rel.weak?
			end
		    end
		end

		(roots.to_value_set - finishing - gc_quarantine).each do |local_task|
		    if local_task.pending? 
			Roby::Propagation.info "GC: removing pending task #{local_task}"
			remove_object(local_task)
			did_something = true
		    elsif local_task.starting?
			# wait for task to be started before killing it
			Roby::Propagation.debug { "GC: #{local_task} is starting" }
		    elsif local_task.finished?
			Roby::Propagation.debug { "GC: #{local_task} is not running, removed" }
			remove_object(local_task)
			did_something = true
		    elsif !local_task.finishing?
			if local_task.event(:stop).controlable?
			    Roby::Propagation.debug { "GC: queueing #{local_task}/stop" }
			    if !local_task.respond_to?(:stop!)
				Roby::Propagation.fatal "something fishy: #{local_task}/stop is controlable but there is no #stop! method"
				gc_quarantine << local_task
			    else
				finishing << local_task
				Roby.once do
				    Roby::Propagation.debug { "GC: stopping #{local_task}" }
				    local_task.stop!(nil)
				end
			    end
			else
			    Roby::Propagation.warn "GC: ignored #{local_task}, it cannot be stopped"
			    gc_quarantine << local_task
			end
		    elsif local_task.finishing?
			Roby::Propagation.debug { "GC: waiting for #{local_task} to finish" }
		    else
			Roby::Propagation.warn "GC: ignored #{local_task}"
		    end
		end
	    end

	    unneeded_events.each do |event|
		remove_object(event)
	    end
	end

end

module Roby
    class MainPlan < Plan
        include Propagation
    end

    class << self
	# Returns the executed plan. This is equivalent to
	#   Roby.control.plan
	attr_reader :plan
    end

    # Define a global exception handler on the main plan's execution engine.
    # See also #on_exception
    def self.on_exception(*matchers, &handler)
        Roby.plan.on_exception(*matchers, &handler)
    end

    # Execute the given block in the main plan's propagation context, but don't
    # wait for its completion like Roby.execute does
    def self.once
        Roby.plan.once { yield }
    end

    # Stops the current thread until the given even is emitted. If the event
    # becomes unreachable, an UnreachableEvent exception is raised.
    def self.wait_until(ev)
        if Roby.inside_control?
            raise ThreadMismatch, "cannot use #wait_until in control thread"
        end

        condition_variable(true) do |cv, mt|
            caller_thread = Thread.current

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


