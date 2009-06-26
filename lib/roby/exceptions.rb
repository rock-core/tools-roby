class Exception
    def pretty_print(pp)
        pp.text "#{message} (#{self.class.name})"
        pp.breakable
        Roby.pretty_print_backtrace(pp, backtrace)
    end
    
    # True if +obj+ is involved in this error
    def involved_plan_object?(obj)
        false
    end
end

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
	def initialize(exception)
	    @exception = exception
	    @trace = Array.new
	    @siblings = [self]

	    if task = exception.failed_task
		@trace << exception.failed_task
	    end
	    if generator = exception.failed_generator
		@generator = exception.failed_generator
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

	    new_top    = (Array[*topstack] | Array[*s_topstack])
            new_top = new_top.first if new_top.size == 1
	    @trace = [origin] + (trace | sibling.trace) << new_top
	end

	def initialize_copy(from)
	    super
	    @trace = from.trace.dup
	end
    end

    # This module is to be included in all objects that are
    # able to handle exception. These objects should define
    #   #each_exception_handler { |matchers, handler| ... }
    #
    # See Task::on_exception and Task#on_exception
    module ExceptionHandlingObject
        # To be used in exception handlers themselves. Passes the exception to
        # the next matching exception handler
	def pass_exception
	    throw :next_exception_handler
	end

	# Calls the exception handlers defined in this task for +exception_object.exception+
	# Returns true if the exception has been handled, false otherwise
	def handle_exception(exception_object)
	    each_exception_handler do |matchers, handler|
		if matchers.find { |m| m === exception_object.exception }
		    catch(:next_exception_handler) do 
			begin
			    handler.call(self, exception_object)
			    return true
			rescue Exception => e
			    if !kind_of?(PlanObject)
				engine.add_framework_error(e, 'global exception handling')
			    else
				engine.add_error(FailedExceptionHandler.new(e, self, exception_object))
			    end
			end
		    end
		end
	    end
	    return false
	end
    end

    RX_IN_FRAMEWORK = /^((?:\s*\(druby:\/\/.+\)\s*)?#{Regexp.quote(ROBY_LIB_DIR)}\/)/
    def self.filter_backtrace(original_backtrace)
	if Roby.app.filter_backtraces? && original_backtrace
            app_dir = if defined? APP_DIR then Regexp.quote(APP_DIR) end

            original_backtrace = original_backtrace.dup
            backtrace_bottom   = []
            while !original_backtrace.empty? && original_backtrace.last !~ RX_IN_FRAMEWORK
                backtrace_bottom.unshift original_backtrace.pop
            end

            backtrace = original_backtrace.dup

            while !backtrace.empty? && !backtrace.last
                backtrace.pop
            end
            backtrace.each_with_index do |line, i|
                backtrace[i] = line || original_backtrace[i]
            end

            if app_dir
                backtrace = backtrace.map do |line|
                    line.gsub /^#{app_dir}\/?/, './'
                end
            end
            backtrace.concat backtrace_bottom
	end
	backtrace || original_backtrace || []
    end

    def self.pretty_print_backtrace(pp, backtrace)
        if backtrace && !backtrace.empty?
            pp.group(2) do
                pp.seplist(filter_backtrace(backtrace)) { |line| pp.text line }
            end
        end
    end

    def self.format_exception(exception)
        message = begin
                      PP.pp(exception, "")
                  rescue Exception => formatting_error
                      begin
                          "error formatting exception\n" +
                              exception.full_message +
                          "\nplease report the formatting error: \n" + 
                              formatting_error.full_message
                      rescue Exception => formatting_error
                          "\nerror formatting exception\n" +
                              formatting_error.full_message
                      end
                  end
        message.split("\n")
    end

    def self.log_exception(e, logger, level)
        format_exception(e).each do |line|
            logger.send(level, line)
        end
    end
end

