require 'roby/support'
require 'roby/exceptions'
require 'utilrb/exception/full_message'
require 'utilrb/unbound_method'

# This module contains all code necessary for the propagation steps during execution. This includes
# event propagation and exception propagation
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
    def self.source_events; Thread.current[:propagation_events] end
    def self.source_generators; Thread.current[:propagation_generators] end
    def self.propagation_id; Thread.current[:propagation_id] end
    def self.pending_event?(generator)
	Thread.current[:current_propagation_set].has_key?(generator)
    end

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
	Thread.current[:current_propagation_set] ||= Hash.new

	propagation_context(nil) { yield }

	return Thread.current[:propagation]
    ensure
	Thread.current[:propagation] = nil
	Thread.current[:current_propagation_set] = nil
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
    def self.gather_exceptions(source = nil)
	begin
	    yield
	    false

	rescue Exception => e
	    if Thread.current[:propagation_exceptions] && (plan_exception = to_execution_exception(e, source))
		Thread.current[:propagation_exceptions] << plan_exception
	    elsif Thread.current[:application_exceptions]
		Thread.current[:application_exceptions] << [source, e]
	    else
		Roby.application_error('unknown', source, e)
	    end
	    true
	end
    end

    # Sets the source_event and source_generator variables according
    # to +source+. +source+ is the +from+ argument of #add_event_propagation
    def self.propagation_context(sources)
	raise "not in a gathering context in #fire" unless gathering?

	if sources
	    event, generator = source_events, source_generators

	    Thread.current[:propagation_events], Thread.current[:propagation_generators] = 
		sources.inject([[], []]) do |(e, g), s|
		    if s.respond_to?(:generator)
			e << s
			g << s.generator
		    else
			e << nil
			g << s
		    end
		    [e, g]
		end
	else
	    Thread.current[:propagation_events], Thread.current[:propagation_generators] = [], []
	end

	yield Thread.current[:propagation]

    ensure
	Thread.current[:propagation_event] = event
	Thread.current[:propagation_generator] = generator
    end

    # Adds a propagation to the next propagation step. More specifically, it
    # adds either forwarding or signalling the set of Event objects +from+ to
    # the +signalled+ event generator, with the context +context+
    def self.add_event_propagation(only_forward, from, signalled, context, timespec)
	step = (Thread.current[:propagation][signalled] ||= [only_forward])

	if step.first != only_forward
	    raise PropagationException.new(from), "both signalling and forwarding to #{signalled}"
	end
	from = [nil] unless from && !from.empty?
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
	    gather_exceptions { yield(initial_set) } if block_given?
	    seeds.each do |s|
		gather_exceptions { s.call }
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

    def self.make_delay(timeref, source, signalled, timespec)
	if delay = timespec[:delay] then timeref + delay
	elsif at = timespec[:at] then at
	else
	    raise "invalid timespec #{timespec}"
	end
    end


    def self.event_propagation_step(current_step, already_seen)
	timeref = Time.now

	Thread.current[:current_propagation_set] = current_step

	terminal, other = nil
	current_step.each do |signalled, _| 
	    if signalled.respond_to?(:terminal?) && signalled.terminal?
		terminal = signalled
	    else
		other = signalled
		break
	    end
	end

	signalled = other || terminal
	forward, *info = current_step.delete(signalled)

	sources, context = [], []

	# Will be set to false if there is one immediate propagation
	delayed = true
	info.each_slice(3) do |src, ctxt, time|
	    if time && (delay = make_delay(timeref, src, signalled, time))
		add_event_delay(delay, forward, src, signalled, ctxt)
		next
	    end

	    delayed = false

	    # Merge identical signals. Needed because two different event handlers
	    # can both call #emit, and two signals are set up
	    next if src && sources.include?(src)

	    sources << src if src
	    context << ctxt if ctxt
	end
	context = *context
	return current_step if delayed

	if !forward && signalled.controlable?
	    sources.each { |source| source.generator.signalling(source, signalled) }
	else
	    sources.each { |source| source.generator.forwarding(source, signalled) }
	end

	if already_seen.include?(signalled) && !(forward && signalled.pending?) 
	    # Do not fire the same event twice in the same propagation cycle
	    return current_step unless signalled.propagation_mode == :always_call
	end

	next_step = gather_propagation(current_step) do
	    did_call = false
	    propagation_context(sources) do |result|
		gather_exceptions(signalled) do
		    if !forward && signalled.controlable?
			did_call = signalled.call_without_propagation(context) 
		    else
			did_call = signalled.emit_without_propagation(context)
		    end
		end
	    end

	    already_seen << signalled if did_call
	end

	current_step.merge!(next_step)
    end

    # Performs exception propagation for the given ExecutionException objects
    # Returns all exceptions which have found no handlers in the task hierarchy
    def self.propagate_exceptions(exceptions)
	fatal   = [] # the list of exceptions for which no handler has been found

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
		    new_exceptions |= task_exceptions.map { |e| [e, [task]] }
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
	#   [exception_handling]:: error in exception handler. +origin+ is either
	#			   the task of the handler or the Roby module for
	#			   global exceptions
	#
	def application_error(event, origin, error)
	    if Thread.current[:application_exceptions]
		Thread.current[:application_exceptions] << [[event, origin], error]
	    elsif Control.instance.abort_on_application_exception || error.kind_of?(SignalException)
		raise error
	    else
		Roby.error "Application error during #{event} in #{origin}:#{error.full_message}"
	    end

	    nil
	end
    end
end


