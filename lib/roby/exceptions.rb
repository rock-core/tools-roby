module Roby
    class ConfigError < RuntimeError; end
    class ModelViolation < RuntimeError; end

    # This task is used during event processing to encapsulate an exception
    # that occured during event propagation
    class ExecutionException
	# The exception source, can be nil
	attr_reader :stack
	# The top of the stack
	def task; stack.last end
	# The exception siblings (the ExecutionException objects
	# that come from the same exception object)
	attr_reader :siblings
	# The exception generator
	attr_reader :generator
	# The exception object
	attr_reader :exception
	# A list of propagation that have not been done
	# because of exception handling
	attr_reader :discarded

	# If this specific exception has been marked has handled
	attr_accessor :handled
	# If this exception or one of its siblings has been marked as handled
	def handled?
	    siblings.find { |s| s.handled }
	end
	# Enumerates this exception's siblings
	def each_sibling
	    siblings.each { |e| yield(e) unless e == self }
	end

	def initialize(exception, source = nil)
	    @exception = exception
	    @discarded = Array.new
	    @stack = Array.new
	    @siblings = [self]

	    if source
		if source.respond_to?(:to_task)
		    @stack << source
		elsif EventGenerator === source
		    @generator = source
		end
	    else
		if exception.respond_to?(:task)
		    @stack << exception.task
		end
		if exception.respond_to?(:generator)
		    @generator = exception.generator
		end
	    end

	    if !task && generator.respond_to?(:task)
		@stack << generator.task
	    end
	end

	# Create a sibling from this exception
	def fork
	    sibling = dup
	    self.siblings << sibling
	    sibling
	end

	def merge(sibling)
	    siblings.delete(sibling)
	    topstack = stack.pop
	    s_topstack = sibling.stack.pop
	    @stack |= sibling.stack
	    @stack << Array[*topstack] + Array[*s_topstack]
	end

	def initialize_copy(from)
	    super
	    @stack = from.stack.dup
	end
    end

    # Performs exception propagation for the given ExecutionException objects
    # Returns all exceptions which have found no handlers
    def self.propagate_exceptions(exceptions)
	fatal   = [] # the list of exceptions for which no handler has been found

	while !exceptions.empty?
	    by_task = Hash.new { |h, k| h[k] = Array.new }
	    by_task = exceptions.inject(by_task) do |by_task, e|	
		unless e.task
		    raise NotImplementedError, "we do not yet handle exceptions from external event generators"
		end

		has_parent = false
		e.task.each_parent_object(TaskStructure::Hierarchy) do |parent|
		    e = e.fork if has_parent # we have more than one parent
		    exceptions = by_task[parent] 
		    if s = exceptions.find { |s| s.siblings.include?(e) }
			s.merge(e)
		    else exceptions << e
		    end

		    has_parent = true
		end

		fatal << e unless has_parent
		by_task
	    end

	    parent_trees = by_task.map do |task, _|
		[task, task.reverse_directed_component(TaskStructure::Hierarchy)]
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

	# Remove from fatal the exceptions which have a sibling which has
	# been handled
	fatal.find_all { |e| !e.handled? }
    end
    # Hook called when an exception +e+ has been handled by +task+
    def self.handled_exception(e, task); super if defined? super end

end

