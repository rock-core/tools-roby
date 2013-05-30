require 'highline'

class Exception
    def pretty_print(pp)
        if backtrace && !backtrace.empty?
            pp.text "#{backtrace[0]}: #{message} (#{self.class.name})"
        else
            pp.text "#{message} (#{self.class.name})"
        end
    end
    
    # True if +obj+ is involved in this error
    def involved_plan_object?(obj)
        false
    end
end

module Roby
    class ConfigError < RuntimeError; end
    class ModelViolation < RuntimeError; end
    class InternalError < RuntimeError; end

    class << self
        attr_reader :console
    end
    @console = HighLine.new
    def self.color(*args)
        console.color(*args)
    end

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
        # If true, the underlying exception is a fatal error, i.e. should cause
        # parent tasks to be stopped if unhandled.
        def fatal?; exception.fatal? end
    
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
        # Enumerates all tasks that are involved in this exception (either
        # origin or in the trace)
        def each_involved_task
            return enum_for(:each_involved_task) if !block_given?
            trace.each do |tr|
                if tr.respond_to?(:to_ary)
                    tr.each { |t| yield(t) }
                else
                    yield(tr)
                end
            end
        end

        # True if this exception originates from the given task or generator
        def originates_from?(object)
            generator == object || (generator.respond_to?(:task) && generator.task == object)
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
        module ClassExtension
            extend MetaRuby::Attributes
            inherited_attribute('exception_handler', 'exception_handlers') { Array.new }
        end

        # To be used in exception handlers themselves. Passes the exception to
        # the next matching exception handler
	def pass_exception
	    throw :next_exception_handler
	end

        def add_error(error)
            engine.additional_errors << error
        end

	# Calls the exception handlers defined in this task for +exception_object.exception+
	# Returns true if the exception has been handled, false otherwise
	def handle_exception(exception_object)
	    each_exception_handler do |matcher, handler|
                if matcher === exception_object
		    catch(:next_exception_handler) do 
			begin
			    handler.call(self, exception_object)
			    return true
			rescue Exception => e
			    if !kind_of?(PlanObject)
				engine.add_framework_error(e, 'global exception handling')
			    else
				add_error(FailedExceptionHandler.new(e, self, exception_object))
			    end
			end
		    end
		end
	    end
	    return false
	end
    end

    def self.filter_backtrace(original_backtrace = nil, options = Hash.new)
        filter_out = Roby.app.filter_out_patterns

        if !original_backtrace && block_given?
            begin
                return yield
            rescue Exception => e
                raise e, e.message, filter_backtrace(e.backtrace)
            end
        end

	if (Roby.app.filter_backtraces? || options[:force]) && original_backtrace
            app_dir = Roby.app.app_dir

            original_backtrace = original_backtrace.dup

            # First, read out the "bottom" of the backtrace: search for the
            # first backtrace line that is within the framework
            backtrace_bottom   = []
            while !original_backtrace.empty? && !filter_out.any? { |rx| rx =~ original_backtrace.last }
                backtrace_bottom.unshift original_backtrace.pop
            end

            got_user_line = false
            backtrace = original_backtrace.enum_for(:each_with_index).map do |line, idx|
                case line
                when /in `poll_handler'$/
                    got_user_line = true
                    line.gsub(/:in.*/, ':in the polling handler')
                when /in `event_command_(\w+)'$/
                    got_user_line = true
                    line.gsub(/:in.*/, ":in command for '#{$1}'")
                when /in `event_handler_(\w+)_(?:[a-f0-9]+)'$/
                    got_user_line = true
                    line.gsub(/:in.*/, ":in event handler for '#{$1}'")
                else
                    if original_backtrace.size > idx + 4 &&
                        original_backtrace[idx + 1] =~ /in `call'$/ &&
                        original_backtrace[idx + 2] =~ /in `call_handlers'$/ &&
                        original_backtrace[idx + 3] =~ /`each'$/ &&
                        original_backtrace[idx + 4] =~ /`each_handler'$/

                        got_user_line = true
                        line.gsub(/:in /, ":in event handler, ")
                    else
                        is_user = !filter_out.any? { |rx| rx =~ line }
                        got_user_line ||= is_user
                        if !got_user_line || is_user
                            case line
                            when /^\(eval\):\d+:in `each(?:_handler)?'/
                            else
                                line
                            end
                        end
                    end
                end
            end

            backtrace.compact!

            if app_dir
                backtrace = backtrace.map do |line|
                    line.gsub(/^#{app_dir}\/?/, './')
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

    def self.log_pp(obj, logger, level)
        if logger.respond_to?(:logger)
            logger = logger.logger
        end

        logger.send(level) do
            first_line = true
            format_exception(obj).each do |line|
                if first_line
                    line = color(line, :bold, :red)
                    first_line = false
                end
                logger.send(level, line)
            end
            break
        end
    end

    def self.log_exception(e, logger, level)
        log_pp(e, logger, level)
    end

    def self.log_backtrace(e, logger, level)
        format_exception(BacktraceFormatter.new(e)).each do |line|
            logger.send(level, line)
        end
    end

    def self.log_exception_with_backtrace(e, logger, level)
        log_exception(e, logger, level)
        logger.send level, color("= Backtrace", :bold, :red)
        log_backtrace(e, logger, level)
        logger.send level, color("= ", :bold, :red)
    end

    class BacktraceFormatter
        def initialize(exception)
            @exception = exception
        end
        def full_message
            @exception.full_message
        end

        def pretty_print(pp)
            Roby.pretty_print_backtrace(pp, @exception.backtrace)
        end
    end
    def self.do_display_exception(io, e)
        first_line = true
        io.puts ""
        format_exception(e).each do |line|
            if first_line
                io.print color("= ", :bold, :red)
                io.puts color(line, :bold, :red)
                first_line = false
            else
                io.print color("| ", :bold, :red)
                io.puts line
            end
        end
        io.puts color("= Backtrace", :bold, :red)
        format_exception(BacktraceFormatter.new(e)).each do |line|
            io.print color("| ", :bold, :red)
            io.puts line
        end
        io.puts color("= ", :bold, :red)
        true
    end


    def self.display_exception(io = STDOUT, e = nil, filter_backtraces = nil)
        if !filter_backtraces.nil?
            old_filter_backtraces = Roby.app.filter_backtraces?
            Roby.app.filter_backtraces = filter_backtraces
        end

        if !block_given?
            if !e
                raise ArgumentError, "expected an exception object as no block was given"
            end
            do_display_exception(io, e)
            e
        else
            yield
            false
        end

    rescue Exception => e
        do_display_exception(io, e)
        e

    ensure
        if !filter_backtraces.nil?
            Roby.app.filter_backtraces = old_filter_backtraces
        end
    end
end

