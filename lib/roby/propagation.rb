require 'roby/support'
require 'roby/exceptions'
require 'utilrb/exception/full_message'

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

    # This module is to be included in all objects that are
    # able to handle exception. These objects should define
    # #each_exception_handler { |matchers, handler| ... }
    module ExceptionHandlingObject
	# Passes the exception to the next matching exception handler
	def pass_exception
	    throw :next_exception_handler
	end

	# Calls the exception handlers defined in this task for +exception_object.exception+
	# Returns true if the exception has been handled, false otherwise
	def handle_exception(exception_object)
	    each_exception_handler do |matchers, handler|
		if matchers.find { |m| m === exception_object.exception }
		    begin
			catch(:next_exception_handler) do 
			    handler.call(self, exception_object)
			    return true
			end
		    rescue Exception => handler_error
			Roby.application_error(:exception_handling, handler_error, self)
		    end
		end
	    end
	    return false
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

    # Begin an event propagation stage
    def self.gather_propagation
	raise "nested call to #gather_propagation" if gathering?
	Thread.current[:propagation] = Hash.new
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
	Roby.error <<-EOM
got an exception which did not specify its source
#{error.full_message}
	EOM
	nil
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

	rescue RuntimeError => e
	    e = to_execution_exception(e, source)
	    Thread.current[:propagation_exceptions] << e if e
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
    def self.add_event_propagation(only_forward, from, signalled, context)
	step = (Thread.current[:propagation][signalled] ||= [only_forward])

	if step.first != only_forward
	    raise PropagationException.new(from), "both signalling and forwarding to #{signalled}"
	end
	from = [nil] unless from && !from.empty?
	from.each do |ev|
	    step << ev << context
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
	return Thread.current[:propagation_exceptions]

    ensure
	Thread.current[:propagation_id] = nil
	Thread.current[:propagation_exceptions] = nil
    end

    def self.event_propagation_step(current_step, already_seen)
	Thread.current[:current_propagation_set] = current_step
	gather_propagation do
	    # Note that internal signalling does not need a #call
	    # method (hence the respond_to? check). The fact that the
	    # event can or cannot be fired is checked in #fire (using can_signal?)
	    current_step.each do |signalled, (forward, *info)|
		sources, context = [], []
		info.each_slice(2) do |s, c|
		    sources << s if s
		    context << c if c
		end
		context = *context

		if !forward && signalled.controlable?
		    sources.each { |source| source.generator.signalling(source, signalled) }
		else
		    sources.each { |source| source.generator.forwarding(source, signalled) }
		end

		if already_seen.include?(signalled) && !(forward && signalled.pending?) 
		    # Do not fire the same event twice in the same propagation cycle
		    next unless signalled.propagation_mode == :always_call
		end

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
	end
    end

    # Performs exception propagation for the given ExecutionException objects
    # Returns all exceptions which have found no handlers in the task hierarchy
    def self.propagate_exceptions(exceptions)
	fatal   = [] # the list of exceptions for which no handler has been found

	while !exceptions.empty?
	    by_task = Hash.new { |h, k| h[k] = Array.new }
	    by_task = exceptions.inject(by_task) do |by_task, (e, parents)|
		unless e.task
		    raise NotImplementedError, "we do not yet handle exceptions from external event generators"
		end
		parents ||= e.task.parent_objects(Roby::TaskStructure::Hierarchy)

		has_parent = false
		[*parents].each do |parent|
		    next if parent.finished?

		    e = e.fork if has_parent # we have more than one parent
		    exceptions = by_task[parent] 
		    if s = exceptions.find { |s| s.siblings.include?(e) }
			s.merge(e)
		    else exceptions << e
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

	    # Handle the exception in all tasks that are in no other parent
	    # trees
	    new_exceptions = ValueSet.new
	    by_task.each do |task, task_exceptions|
		if parent_trees.find { |t, tree| t != task && tree.include?(task) }
		    new_exceptions |= task_exceptions
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
	include Propagation::ExceptionHandlingObject

	# Called when an exception has been raised by application code. +error+ is the
	# exception itself and +origin+ its origin.
	#
	# +event+ can be one of:
	#   [exception_handling]:: error in exception handler. +origin+ is either
	#			   the task of the handler or the Roby module for
	#			   global exceptions
	#
	def application_error(event, error, origin)
	    if Control.instance.abort_on_application_exception || error.kind_of?(SignalException)
		raise error
	    else
		Roby.error "Application error during #{event} in #{origin}:#{error.full_message}"
	    end

	    nil
	end
    end
end


