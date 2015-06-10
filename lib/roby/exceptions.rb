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

    def user_error?; false end

    # DRoby-marshalling is done in distributed/protocol
end


module Roby
    class UserError < RuntimeError
        def user_error?; true end
    end
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
    
	# The origin EventGenerator if there is one
	attr_reader :generator
	# The exception object
	attr_reader :exception

	# If this specific exception has been marked has handled
	attr_accessor :handled
	# If this exception has been marked as handled
	def handled?
	    handled
	end
        # Enumerates all tasks that are involved in this exception (either
        # origin or in the trace)
        def each_involved_task
            return enum_for(:each_involved_task) if !block_given?
            trace.each do |tr|
                yield(tr)
            end
        end

        # Resets the trace to [origin]
        def reset_trace
            @trace = [origin]
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
	    dup
	end

	# Merges +sibling+ into this object
	def merge(sibling)
            new_trace = sibling.trace.find_all do |t|
                !trace.include?(t)
            end
            @trace = self.trace + new_trace
            self
	end

	def initialize_copy(from)
	    super
	    @trace = from.trace.dup
	end

        def to_execution_exception
            self
        end

        def pretty_print(pp)
            pp.text "from #{origin} with trace "
            pp.nest(2) do
                pp.breakable
                pp.nest(2) do
                    trace.each do |t|
                        pp.breakable
                        pp.text t.to_s
                    end
                end
                pp.breakable
                pp.text "Exception:"
                pp.nest(2) do
                    pp.breakable
                    exception.pretty_print(pp)
                end
            end
        end

        class DRoby
            attr_reader :trace
            attr_reader :exception
            attr_reader :handled

            def initialize(trace, exception, handled)
                @trace, @exception, @handled = trace, exception, handled
            end

            def proxy(peer)
                trace     = peer.local_object(self.trace)
                exception = peer.local_object(self.exception)
                result = ExecutionException.new(exception)
                result.trace.clear
                result.trace.concat(trace)
                result.handled = self.handled
                result
            end
        end

        def droby_dump(peer = nil)
            DRoby.new(trace.droby_dump(peer),
                      exception.droby_dump(peer),
                      handled)
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
            engine.add_error(error)
        end

	# Calls the exception handlers defined in this task for +exception_object.exception+
	# Returns true if the exception has been handled, false otherwise
	def handle_exception(exception_object)
	    each_exception_handler do |matcher, handler|
                if exception_object.exception.kind_of?(FailedExceptionHandler)
                    # Do not handle a failed exception handler by itself
                    next if exception_object.exception.handler == handler
                end

                if matcher === exception_object
		    catch(:next_exception_handler) do 
			begin
			    handler.call(self, exception_object)
			    return true
			rescue Exception => e
			    if !kind_of?(PlanObject)
				engine.add_framework_error(e, 'global exception handling')
			    else
				add_error(FailedExceptionHandler.new(e, self, exception_object, handler))
			    end
			end
		    end
		end
	    end
	    return false
	end
    end

    def self.filter_backtrace(original_backtrace = nil, options = Hash.new)
        options = Kernel.validate_options options, :force => false, :display_full_framework_backtraces => false
        filter_out = Roby.app.filter_out_patterns

        if !original_backtrace && block_given?
            begin
                return yield
            rescue Exception => e
                raise e, e.message, filter_backtrace(e.backtrace, options)
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
            if original_backtrace.size == backtrace.size && !options[:display_full_framework_backtraces]
                # The backtrace is only within the framework, make it empty
                backtrace = []
            end
	end
	backtrace || original_backtrace || []
    end

    def self.pretty_print_backtrace(pp, backtrace, options = Hash.new)
        if backtrace && !backtrace.empty?
            pp.nest(2) do
                filter_backtrace(backtrace, options).each do |line|
                    pp.breakable
                    pp.text line
                end
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

    rescue Interrupt, SystemExit
        raise
    rescue Exception => e
        if e.user_error?
            io.print color(e.message, :bold, :red)
        else
            do_display_exception(io, e)
        end
        e

    ensure
        if !filter_backtraces.nil?
            Roby.app.filter_backtraces = old_filter_backtraces
        end
    end
end

