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

end

