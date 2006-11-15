require 'roby/exceptions'

# This module contains all code necessary for the propagation steps during execution. This includes
# event propagation and exception propagation
module Roby::Propagation
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
		    catch(:next_exception_handler) do 
			handler[self, exception_object]
			return true
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

    # Begin a propagation stage
    def self.gather_propagation
	raise "nested call to #gather_propagation" if gathering?
	Thread.current[:propagation] = Hash.new

	propagation_context(nil) do
	    yield
	end

	return Thread.current[:propagation]
    ensure
	Thread.current[:propagation] = nil
    end

    # Sets the source_event and source_generator variables according
    # to +source+. +source+ is the +from+ argument of #add_propagation_step
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

    # Adds a propagation to the next propagation step
    def self.add_event_propagation(only_forward, from, signalled, context)
	step = (Thread.current[:propagation][signalled] ||= [nil, [], []])

	if !step[0].nil? && step[0] != only_forward
	    raise PropagationException.new(from), "both signalling and forwarding to #{signalled}"
	end

	step[0] = only_forward
	step[1] += from if from
	step[2] << context if context
    end

    # Calls its block in a #gather_propagation context and propagate events
    # that have been called and/or emitted by the block
    #
    # the block argument is the initial set of events: the events we should
    # consider as already emitted in the following propagation
    def self.propagate_events
	return if !propagate?

	Thread.current[:propagation_id] = (@@propagation_id += 1)

	initial_set = []
	next_step = gather_propagation do
	    yield(initial_set)
	end

	# Problem with postponed: the object is included in already_seen while it
	# has not been fired
	already_seen = initial_set.to_set

	while !next_step.empty?
	    next_step = event_propagation_step(next_step, already_seen)
	end        
	return self

    ensure
	Thread.current[:propagation_id] = nil
    end

    def self.event_propagation_step(current_step, already_seen)
	gather_propagation do
	    # Note that internal signalling does not need a #call
	    # method (hence the respond_to? check). The fact that the
	    # event can or cannot be fired is checked in #fire (using can_signal?)
	    current_step.each do |signalled, (forward, sources, context)|
		context = *context

		sources.each do |source|
		    source.generator.signalling(source, signalled) if source
		end

		if already_seen.include?(signalled) && !(forward && signalled.pending?) 
		    # Do not fire the same event twice in the same propagation cycle
		    next unless signalled.propagation_mode == :always_call
		end

		did_call = propagation_context(sources) do |result|
		    if !forward && signalled.controlable?
			signalled.call_without_propagation(context) 
		    else
			signalled.emit_without_propagation(context)
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
	    by_task = exceptions.inject(by_task) do |by_task, e|	
		unless e.task
		    raise NotImplementedError, "we do not yet handle exceptions from external event generators"
		end

		has_parent = false
		e.task.each_parent_object(Roby::TaskStructure::Hierarchy) do |parent|
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
		[task, task.reverse_directed_component(Roby::TaskStructure::Hierarchy)]
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
		    if task.handle_exception(e)
			handled_exception(e, task)
			e.handled = true
		    elsif !e.handled?
			# We do not have the framework to handle concurrent repairs
			# For now, the first handler is the one ... 
			new_exceptions << e
			e.stack << task
		    end
		end
	    end

	    exceptions = new_exceptions
	end

	# Call global exception handlers for exceptions in +fatal+. Return the
	# set of still unhandled exceptions
	fatal.
	    find_all { |e| !e.handled? }.
	    find_all { |e| !Roby.handle_exception(e) }
    end
    # Hook called when an exception +e+ has been handled by +task+
    def self.handled_exception(e, task); super if defined? super end
end

module Roby
    @exception_handlers = Array.new
    class << self
	attr_reader :exception_handlers
	def each_exception_handler(&iterator); exception_handlers.each(&iterator) end
	# define_method(:each_exception_handler, &Roby::Propagation.exception_handlers.method(:each))
	def on_exception(*matchers, &handler); exception_handlers.unshift [matchers, handler] end
	include Propagation::ExceptionHandlingObject
    end
end


