require 'roby/support'
require 'roby/exceptions'
require 'utilrb/exception/full_message'
require 'utilrb/unbound_method'
require 'roby/relations/error_handling'

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
#
module Roby::Propagation
    extend Logger::Hierarchy
    extend Logger::Forward

    class PropagationException < Roby::ModelViolation
	attr_reader :sources
	def initialize(sources)
	    @sources = sources
	end
    end

    @@propagate = true
    def self.disable_propagation; @@propagate = false end
    def self.enable_propagation; @@propagate = true end
    def self.propagate?; @@propagate end

    @@propagation_id = 0

    # If we are currently in the propagation stage
    def self.gathering?; !!Thread.current[:propagation] end
    # The set of source events for the current propagation action. This is a
    # mix of EventGenerator and Event objects.
    def self.sources; Thread.current[:propagation_sources] end
    # The set of generators extracted from Propagation.sources
    def self.source_generators
	result = ValueSet.new
	for ev in Thread.current[:propagation_sources]
	    result << if ev.respond_to?(:generator)
			  ev.generator
		      else
			  ev
		      end
	end
	result
    end
    def self.propagation_id; Thread.current[:propagation_id] end

    @@delayed_events = []
    def self.delayed_events; @@delayed_events end
    def self.add_event_delay(time, forward, source, signalled, context)
	delayed_events << [time, forward, source, signalled, context]
    end
    def self.execute_delayed_events
	reftime = Time.now
	delayed_events.delete_if do |time, forward, source, signalled, context|
	    if time < reftime
		add_event_propagation(forward, [source], signalled, context, nil)
		true
	    end
	end
    end
    module RemoveDelayedOnFinalized
	def finalized_event(event)
	    super if defined? super
	    Roby::Propagation.delayed_events.delete_if { |_, _, _, signalled, _| signalled == event }
	end
    end
    Roby::Plan.include RemoveDelayedOnFinalized
    Roby::Control.event_processing << Roby::Propagation.method(:execute_delayed_events)

    # Begin an event propagation stage
    def self.gather_propagation(initial_set = Hash.new)
	raise "nested call to #gather_propagation" if gathering?
	Thread.current[:propagation] = initial_set

	propagation_context(nil) { yield }

	return Thread.current[:propagation]
    ensure
	Thread.current[:propagation] = nil
    end

    def self.to_execution_exception(error, source = nil)
	Roby::ExecutionException.new(error, source)
    rescue ArgumentError
    end

    # Gather any exception raised by the block and saves it for later
    # processing by the event loop. If +source+ is given, it is used as the
    # exception source
    #
    # Returns +true+ if an exception has been raised
    def self.gather_exceptions(source = nil, modname = 'unknown')
	yield
	false

    rescue Exception => e
	append_exception(e, source, modname)
	true
    end

    def self.append_exception(e, source, modname)
	if Thread.current[:propagation_exceptions] && (plan_exception = to_execution_exception(e, source))
	    Thread.current[:propagation_exceptions] << plan_exception
	elsif Thread.current[:application_exceptions]
	    Thread.current[:application_exceptions] << [source, e]
	else
	    Roby.application_error(modname, source, e)
	end
    end

    # Sets the source_event and source_generator variables according
    # to +source+. +source+ is the +from+ argument of #add_event_propagation
    def self.propagation_context(sources)
	raise "not in a gathering context in #fire" unless gathering?

	if sources
	    current_sources = sources
	    Thread.current[:propagation_sources] = sources
	else
	    Thread.current[:propagation_sources] = []
	end

	yield Thread.current[:propagation]

    ensure
	Thread.current[:propagation_sources] = sources
    end

    # Adds a propagation to the next propagation step. More specifically, it
    # adds either forwarding or signalling the set of Event objects +from+ to
    # the +signalled+ event generator, with the context +context+
    def self.add_event_propagation(forward, from, signalled, context, timespec)
	if signalled.plan != Roby.plan
	    raise "#{signalled} not in main plan"
	end

	step = (Thread.current[:propagation][signalled] ||= [nil, nil])
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
    def self.propagate_events(seeds = [])
	return if !propagate?
	if Thread.current[:propagation_exceptions]
	    raise "recursive call to propagate_events"
	end

	Thread.current[:propagation_id] = (@@propagation_id += 1)
	Thread.current[:propagation_exceptions] = []

	initial_set = []
	next_step = gather_propagation do
	    gather_exceptions(nil, 'initial set setup') { yield(initial_set) } if block_given?
	    gather_exceptions(nil, 'distributed events') { Roby::Distributed.process_remote_events }
	    seeds.each do |s|
		gather_exceptions(s, 'seed') { s.call }
	    end
	end

	# Problem with postponed: the object is included in already_seen while it
	# has not been fired
	already_seen = initial_set.to_set

	while !next_step.empty?
	    next_step = event_propagation_step(next_step, already_seen)
	end        
	Thread.current[:propagation_exceptions]

    ensure
	Thread.current[:propagation_id] = nil
	Thread.current[:propagation_exceptions] = nil
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
	    raise "invalid timespec #{timespec}"
	end
    end

    @event_ordering = Array.new
    @event_priorities = Hash.new
    class << self
	# The topological ordering of events w.r.t. the Precedence relation
	attr_reader :event_ordering
	# The event => index hash which give the propagation priority for each
	# event
	attr_reader :event_priorities
    end

    # This module hooks in plan modifications to clear the event ordering cache
    # (Propagation.event_ordering) when needed.
    #
    # It is included in the main plan by Control#initialize
    module ExecutablePlanChanged
	def discovered_events(objects)
	    super if defined? super
	    Roby::Propagation.event_ordering.clear
	end
	def discovered_tasks(objects)
	    super if defined? super
	    Roby::Propagation.event_ordering.clear
	end
    end
    
    # This module hooks in event relation modifications to clear the event
    # ordering cache (Propagation.event_ordering) when needed.
    module EventPrecedenceChanged
	def added_child_object(child, relations, info)
	    super if defined? super
	    if relations.include?(Roby::EventStructure::Precedence) && plan == Roby.plan
		Roby::Propagation.event_ordering.clear
	    end
	end
	def removed_child_object(child, relations)
	    super if defined? super
	    if relations.include?(Roby::EventStructure::Precedence) && plan == Roby.plan
		Roby::Propagation.event_ordering.clear
	    end
	end
    end
    Roby::EventGenerator.include EventPrecedenceChanged

    # Determines the event in +current_step+ which should be signalled now.
    # Removes it from the set and returns the event and the associated
    # propagation information
    def self.next_event(pending)
	if event_ordering.empty?
	    Roby::EventStructure::Precedence.topological_sort(event_ordering)
	    event_priorities.clear
	    event_ordering.each_with_index do |ev, i|
		event_priorities[ev] = i
	    end
	end

	signalled, min = nil, event_ordering.size
	pending.each_key do |event|
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

    def self.prepare_propagation(signalled, forward, info)
	timeref = Time.now

	source_events, source_generators, context = ValueSet.new, ValueSet.new, []

	delayed = true
	info.each_slice(3) do |src, ctxt, time|
	    if time && (delay = make_delay(timeref, src, signalled, time))
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
    def self.event_propagation_step(current_step, already_seen)
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
			propagation_context(source_generators) do |result|
			    gather_exceptions(signalled) do
				signalled.call_without_propagation(context) 
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
			propagation_context(source_generators) do |result|
			    gather_exceptions(signalled) do
				signalled.emit_without_propagation(context)
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
    def self.remove_inhibited_exceptions(exceptions)
	exceptions.find_all do |e, _|
	    error = e.exception
	    if !error.respond_to?(:failure_point) ||
		!(failure_point = error.failure_point)
		true
	    else
		Roby.plan.repairs_for(failure_point).empty?
	    end
	end
    end

    def self.remove_useless_repairs
	plan = Roby.plan

	finished_repairs = plan.repairs.dup.delete_if { |_, task| task.starting? || task.running? }
	for repair in finished_repairs
	    plan.remove_repair(repair[1])
	end

	finished_repairs
    end

    # Performs exception propagation for the given ExecutionException objects
    # Returns all exceptions which have found no handlers in the task hierarchy
    def self.propagate_exceptions(exceptions)
	fatal   = [] # the list of exceptions for which no handler has been found

	# Remove finished repairs and remove exceptions for which a repair
	# exists
	finished_repairs = remove_useless_repairs
	exceptions = remove_inhibited_exceptions(exceptions)

	# Install new repairs based on the HandledBy task relation. If a repair
	# is installed, remove the exception from the set of errors to handle
	exceptions.delete_if do |e, _|
	    # Check for handled_by relations which would be able to handle +e+
	    error = e.exception
	    next unless error.respond_to?(:failure_point) && (failure_point = error.failure_point)
	    next if finished_repairs.has_key?(failure_point)

	    failure_generator = failure_point.generator
	    next unless failure_generator.respond_to?(:task)

	    failure_task = failure_generator.task
	    repair = failure_task.find_error_handler do |repairing_task, event_set|
		event_set.include?(failure_generator) && !repairing_task.finished?
	    end

	    if repair
		failure_task.plan.add_repair(failure_point, repair)
		true
	    else
		false
	    end
	end

	while !exceptions.empty?
	    by_task = Hash.new { |h, k| h[k] = Array.new }
	    by_task = exceptions.inject(by_task) do |by_task, (e, parents)|
		unless e.task
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
			Roby::Control.handled_exception(e, task)
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
	    reject { |e| Roby.handle_exception(e) }
    end
end

module Roby
    @exception_handlers = Array.new
    class << self
	attr_reader :exception_handlers
	def each_exception_handler(&iterator); exception_handlers.each(&iterator) end
	# define_method(:each_exception_handler, &Roby::Propagation.exception_handlers.method(:each))
	def on_exception(*matchers, &handler); exception_handlers.unshift [matchers, handler] end
	include ExceptionHandlingObject

	# Called when an exception has been raised by application code. +error+ is the
	# exception itself and +origin+ its origin.
	#
	# +event+ can be one of:
	# exception_handling:: error in exception handler. +origin+ is either
	#		       the task of the handler or the Roby module for
	#		       global exceptions
	#
	def application_error(event, origin, error)
	    if Thread.current[:application_exceptions]
		Thread.current[:application_exceptions] << [[event, origin], error]
	    elsif Roby.control.abort_on_application_exception || error.kind_of?(SignalException)
		raise error, "during #{event} in #{origin}: #{error.message}", error.backtrace
	    else
		Roby.error "Application error during #{event} in #{origin}:in #{error.full_message}"
	    end

	    nil
	end
    end
end


