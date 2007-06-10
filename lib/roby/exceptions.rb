module Roby
    class ConfigError < RuntimeError; end
    class ModelViolation < RuntimeError; end

    # ExecutionException objects are used during the exception handling stage
    # to keep information about the propagation. 
    #
    # When a propagation fork is found (for instance, a task with two parents),
    # two or more siblings are created with #fork. If at some point two
    # siblings are to be handled by the same task, coming for instance from two
    # different children, then they are merged with #merge to from one single
    # ExecutionException object.
    class ExecutionException
	# The propagation trace. Because of forks and merges, this should be a
	# graph.  We don't use graph properties (at least not yet), so consider
	# this as the list of objects which did not handle the exeption. Only
	# trace.last and trace.first have a definite meaning: the former
	# is the last object(s) that handled the propagation and the latter
	# is the object from which the exception originated. They can be 
	# accessed through #task and #origin.
	attr_reader :trace
	# The last object(s) that handled the exception. This is either a
	# single object or an array
	def task; trace.last end
	# The object from which the exception originates
	def origin; trace.first end
    
	# The exception siblings (the ExecutionException objects
	# that come from the same exception object)
	attr_reader :siblings
	# The origin EventGenerator if there is one
	attr_reader :generator
	# The exception object
	attr_reader :exception

	# If this specific exception has been marked has handled
	attr_accessor :handled
	# If this exception or one of its siblings has been marked as handled
	def handled?
	    siblings.find { |s| s.handled }
	end
	# Enumerates this exception's siblings
	def each_sibling
	    for e in siblings
		yield(e) unless e == self
	    end
	end

	# Creates a new execution exception object with the specified source
	# If +source+ is nil, tries to guess the source from +exception+: if
	# +exception+ responds to #task or #generator we use either #task or
	# call #generator.task
	def initialize(exception, source = nil)
	    @exception = exception
	    @trace = Array.new
	    @siblings = [self]

	    if source
		if source.respond_to?(:to_task)
		    @trace << source.to_task
		end
		if source.kind_of?(EventGenerator)
		    @generator = source
		end
	    else
		if exception.respond_to?(:task)
		    @trace << exception.task
		end
		if exception.respond_to?(:generator)
		    @generator = exception.generator
		end
	    end

	    if !task && generator.respond_to?(:task)
		@trace << generator.task
	    end

	    if !task && !generator
		raise ArgumentError, "invalid exception specification: cannot get the exception source"
	    end
	end

	# Create a sibling from this exception
	def fork
	    sibling = dup
	    self.siblings << sibling
	    sibling
	end

	# Merges +sibling+ into this object
	def merge(sibling)
	    siblings.delete(sibling)

	    topstack   = trace.pop
	    s_topstack = sibling.trace.pop

	    origin     = trace.shift
	    s_origin   = sibling.trace.shift
	    origin     = origin || s_origin || topstack

	    new_top    = *(Array[*topstack] | Array[*s_topstack])
	    @trace = [origin] + (trace | sibling.trace) << new_top
	end

	def initialize_copy(from)
	    super
	    @trace = from.trace.dup
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
			unless Propagation.gather_exceptions([:exception_handling, self]) { handler.call(self, exception_object) }
			    return true
			end
		    end
		end
	    end
	    return false
	end
    end

    def self.filter_backtrace(backtrace)
	backtrace = backtrace.dup
	backtrace.delete_if do |caller|
	    caller =~ /^((?:\s*\(roby:\/\/.+\)\s*)?#{Regexp.quote(ROBY_LIB_DIR)}|scripts\/)/
	end
	backtrace
    end
end

