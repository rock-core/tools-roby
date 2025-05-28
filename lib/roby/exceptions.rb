# frozen_string_literal: true

require "pp"

module Roby
    class UserError < RuntimeError
        def user_error?
            true
        end
    end

    class ConfigError < RuntimeError; end
    class ModelViolation < RuntimeError; end
    class InternalError < RuntimeError; end

    class << self
        attr_reader :colorizer
    end
    @colorizer = Pastel.new
    def self.color(string, *colors)
        colorizer.decorate(string, *colors)
    end

    def self.disable_colors
        @colorizer = Pastel.new(enabled: false)
    end

    def self.enable_colors_if_available
        @colorizer = Pastel.new
    end

    def self.enable_colors
        @colorizer = Pastel.new(enabled: true)
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
        # The trace of how this exception has been propagated in the plan so far
        #
        # @return [Relations::BidirectionalDirectedAdjacencyGraph]
        attr_reader :trace

        # The last object(s) that handled the exception. This is either a
        # single object or an array
        def propagation_leafs
            trace.each_vertex.find_all { |v| trace.leaf?(v) }
        end

        # The object from which the exception originates
        attr_reader :origin

        # If true, the underlying exception is a fatal error, i.e. should cause
        # parent tasks to be stopped if unhandled.
        def fatal?
            exception.fatal?
        end

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
        def each_involved_task(&block)
            return enum_for(__method__) unless block_given?

            trace.each_vertex(&block)
        end

        def involved_task?(task)
            trace.has_vertex?(task)
        end

        # Resets the trace to [origin]
        def reset_trace
            @trace = Relations::BidirectionalDirectedAdjacencyGraph.new
            @trace.add_vertex(@origin)
        end

        # True if this exception originates from the given task or generator
        def originates_from?(object)
            [generator, origin].include?(object)
        end

        # Creates a new execution exception object with the specified source
        # If +source+ is nil, tries to guess the source from +exception+: if
        # +exception+ responds to #task or #generator we use either #task or
        # call #generator.task
        def initialize(exception)
            @exception = exception
            @trace = Relations::BidirectionalDirectedAdjacencyGraph.new

            if task = exception.failed_task
                @origin = task
                @trace.add_vertex(task)
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

        def propagate(from, to)
            trace.add_edge(from, to)
        end

        # Merges +sibling+ into this object
        #
        # @param [Roby::Task] edge_source the source of the edge in sibling that
        #   led to this merge
        # @param [Roby::Task] edge_target the target of the edge in sibling that
        #   led to this merge
        def merge(sibling)
            @trace.merge(sibling.trace)
            self
        end

        def initialize_copy(from)
            super
            @trace = from.trace.dup
        end

        def to_execution_exception
            self
        end

        def to_s
            PP.pp(self, "".dup)
        end

        def pretty_print(pp)
            pp.text "from #{origin} with trace"
            pp.nest(2) do
                pp.nest(2) do
                    trace.each_edge do |a, b, _|
                        pp.breakable
                        pp.text "#{a} => #{b}"
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
    end

    # This module is to be included in all objects that are
    # able to handle exception. These objects should define
    #   #each_exception_handler { |matchers, handler| ... }
    #
    # See Task::on_exception and Task#on_exception
    module ExceptionHandlingObject
        module ClassExtension
            extend MetaRuby::Attributes
            inherited_attribute("exception_handler", "exception_handlers") { [] }
        end

        # To be used in exception handlers themselves. Passes the exception to
        # the next matching exception handler
        def pass_exception
            throw :next_exception_handler
        end

        def add_error(error, propagate_through: nil)
            execution_engine.add_error(error, propagate_through: propagate_through)
        end

        # Calls the exception handlers defined in this task for +exception_object.exception+
        # Returns true if the exception has been handled, false otherwise
        def handle_exception(exception_object)
            each_exception_handler do |matcher, handler|
                if exception_object.exception.kind_of?(FailedExceptionHandler) &&
                   exception_object.exception.handler == handler
                    # Do not handle a failed exception handler by itself
                    next
                end

                if matcher === exception_object
                    catch(:next_exception_handler) do
                        begin
                            handler.call(self, exception_object)
                            return true
                        rescue Exception => e
                            if !kind_of?(PlanObject)
                                execution_engine.add_framework_error(e, "global exception handling")
                            else
                                add_error(FailedExceptionHandler.new(e, self, exception_object, handler))
                            end
                        end
                    end
                end
            end
            false
        end
    end

    def self.filter_backtrace(
        original_backtrace = nil,
        force: false, display_full_framework_backtraces: false
    )
        return [] unless original_backtrace || block_given?

        if !original_backtrace && block_given?
            begin
                return yield
            rescue Exception => e
                filtered = filter_backtrace(
                    e.backtrace,
                    force: force,
                    display_full_framework_backtraces: display_full_framework_backtraces
                )
                raise e, e.message, filtered
            end
        end

        return original_backtrace unless Roby.app.filter_backtraces? || force

        filter_out = Roby.app.filter_out_patterns
        original_backtrace = original_backtrace.dup

        # First, read out the "bottom" of the backtrace: search for the
        # first backtrace line that is within the framework
        backtrace_bottom = []
        while !original_backtrace.empty? &&
              filter_out.none? { |rx| rx.match?(original_backtrace.last) }
            backtrace_bottom.unshift original_backtrace.pop
        end

        got_user_line = false
        backtrace = original_backtrace.enum_for(:each_with_index).map do |line, idx|
            case line
            when /in `poll_handler'$/
                got_user_line = true
                line.gsub(/:in.*/, ":in the polling handler")
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
                    is_user = filter_out.none? { |rx| rx.match?(line) }
                    got_user_line ||= is_user
                    if !got_user_line || is_user
                        case line
                        when /^\(eval\):\d+:in `each(?:_handler)?'/
                            nil
                        else
                            line
                        end
                    end
                end
            end
        end

        backtrace.compact!
        backtrace = make_backtrace_relative_to_app_dir(backtrace)
        backtrace.concat backtrace_bottom

        if original_backtrace.size == backtrace.size && !display_full_framework_backtraces
            # The backtrace is only within the framework, make it empty
            return []
        end

        backtrace
    end

    def self.make_backtrace_relative_to_app_dir(backtrace)
        return backtrace unless (app_dir = Roby.app.app_dir)

        backtrace.map { |line| line.gsub(/^#{app_dir}\/?/, "./") }
    end

    def self.pretty_print_backtrace(pp, backtrace, **options)
        if backtrace && !backtrace.empty?
            pp.nest(2) do
                filter_backtrace(backtrace, **options).each do |line|
                    pp.breakable
                    pp.text line
                end
            end
        end
    end

    def self.format_one_exception(exception)
        message =
            begin
                PP.pp(exception, "".dup)
            rescue Exception => e
                begin
                    "error formatting exception\n  #{exception.full_message}"\
                    "\nplease report the formatting error:\n  #{e.full_message}"
                rescue Exception => e
                    "error formatting exception\n  #{e.full_message}"
                end
            end

        message.split("\n")
    end

    def self.format_exception(exception, with_original_exceptions: true, with_backtrace: false)
        message = format_one_exception(exception)
        message += format_backtrace(exception) if with_backtrace
        return message unless with_original_exceptions
        return message unless exception.respond_to?(:original_exceptions)

        original_exception_msgs = exception.original_exceptions.flat_map do |original_e|
            format_exception(
                original_e,
                with_original_exceptions: true,
                with_backtrace: with_backtrace
            )
        end
        message + original_exception_msgs
    end

    LOG_SYMBOLIC_TO_NUMERIC = Array[
        :debug,
        :info,
        :warn,
        :error,
        :fatal,
        :unknown]

    def self.log_level_enabled?(logger, level)
        logger_level = if logger.respond_to?(:log_level)
                           logger.log_level
                       else
                           logger.level
                       end

        if numeric_level = LOG_SYMBOLIC_TO_NUMERIC.index(level.to_sym)
            logger_level <= numeric_level
        else
            raise ArgumentError, "#{level} is not a valid log level, log levels are #{LOG_SYMBOLIC_TO_NUMERIC.map(&:inspect).join(', ')}"
        end
    end

    def self.log_pp(obj, logger, level)
        return unless log_level_enabled?(logger, level)

        message =
            begin
                PP.pp(obj, "".dup)
            rescue Exception => e
                begin
                    "error formatting object\n  #{obj}\n"\
                    "please report the formatting error:\n  #{e.full_message}"
                rescue Exception => e
                    "\nerror formatting object\n  #{e.full_message}"
                end
            end

        message.split("\n").each do |line|
            logger.send(level, line)
        end
    end

    def self.log_exception(e, logger, level, with_original_exceptions: true)
        return unless log_level_enabled?(logger, level)

        first_line = true
        format_exception(e, with_original_exceptions: with_original_exceptions).each do |line|
            if first_line
                line = color(line, :bold, :red)
                first_line = false
            end
            logger.send(level, line)
        end
    end

    def self.format_backtrace(e, filter: Roby.app.filter_backtraces?)
        backtrace = e.backtrace
        if filter
            backtrace = filter_backtrace(backtrace)
        end

        format_exception(BacktraceFormatter.new(e, backtrace))
    end

    def self.log_backtrace(e, logger, level, filter: Roby.app.filter_backtraces?)
        format_backtrace(e, filter: filter).each do |line|
            logger.send(level, line)
        end
    end

    def self.log_exception_with_backtrace(e, logger, level, filter: Roby.app.filter_backtraces?, with_original_exceptions: true)
        log_exception(e, logger, level, with_original_exceptions: false)
        logger.send level, color("= Backtrace", :bold, :red)

        backtrace = e.backtrace
        backtrace = filter_backtrace(backtrace) if filter
        if !backtrace || backtrace.empty?
            logger.send level, color("= No backtrace", :bold, :red)
        else
            logger.send level, color("= ", :bold, :red)
            log_backtrace(e, logger, level)
            logger.send level, color("= ", :bold, :red)
        end

        if with_original_exceptions && e.respond_to?(:original_exceptions)
            e.original_exceptions.each do |orig_e|
                log_exception_with_backtrace(orig_e, logger, level, with_original_exceptions: true)
            end
        end
    end

    def self.log_callers(callers, logger, level)
        logger = logger.logger if logger.respond_to?(:logger)

        logger.nest(2, level) do
            callers.each { |line| logger.send(level, line) }
        end
    end

    def self.log_all_threads_backtraces(logger, level)
        current = Thread.current
        Thread.list.each do |thr|
            current = " CURRENT" if current == thr
            logger.send level, "Thread #{thr}#{current}"
            log_callers(thr.backtrace, logger, level)
        end
    end

    def self.log_error(e, logger, level, with_backtrace: true)
        if e.respond_to?(:backtrace) && with_backtrace
            log_exception_with_backtrace(e, logger, level)
        else
            log_exception(e, logger, level)
        end
    end

    class BacktraceFormatter
        attr_reader :backtrace

        def initialize(exception, backtrace = exception.backtrace)
            @exception = exception
            @backtrace = backtrace
        end

        def full_message
            @exception.full_message
        end

        def pretty_print(pp)
            Roby.pretty_print_backtrace(pp, backtrace)
        end
    end

    def self.do_display_exception(
        io, exception, skip_identical_backtraces: true, backtrace: true
    )
        all = [exception]
        if exception.respond_to?(:original_exceptions)
            all += exception.original_exceptions.to_a.flatten
        end

        if skip_identical_backtraces
            last_backtrace = nil
            all =
                all
                .reverse
                .map do |e|
                    skip = (last_backtrace == e.backtrace)
                    last_backtrace = e.backtrace
                    [e, skip]
                end
                .reverse
        end

        all.each do |e, skip_backtrace|
            if colorizer.enabled?
                do_display_exception_formatted(
                    io, e, backtrace: backtrace && !skip_backtrace
                )
            else
                do_display_exception_raw(
                    io, e, backtrace: backtrace && !skip_backtrace
                )
            end
        end
    end

    def self.do_display_exception_raw(io, e, backtrace: true)
        first_line = true
        io.puts
        format_exception(e, with_original_exceptions: false).each do |line|
            if first_line
                io.puts line
                first_line = false
            else
                io.puts "  #{line}"
            end
        end

        return unless backtrace

        format_exception(BacktraceFormatter.new(e)).each do |line|
            io.puts line
        end
        true
    end

    def self.do_display_exception_formatted(io, e, backtrace: true)
        first_line = true
        io.puts ""
        format_exception(e, with_original_exceptions: false).each do |line|
            if first_line
                io.print color("= ", :bold, :red)
                io.puts color(line, :bold, :red)
                first_line = false
            else
                io.print color("| ", :bold, :red)
                io.puts line
            end
        end

        return unless backtrace

        io.puts color("= Backtrace", :bold, :red)
        format_exception(BacktraceFormatter.new(e)).each do |line|
            io.print color("| ", :bold, :red)
            io.puts line
        end
        io.puts color("= ", :bold, :red)
        true
    end

    def self.display_exception(
        io = STDOUT, e = nil,
        filter_backtraces = Roby.app.filter_backtraces?,
        backtrace: true,
        skip_identical_backtraces: true
    )
        old_filter_backtraces = Roby.app.filter_backtraces?
        Roby.app.filter_backtraces = filter_backtraces

        if block_given?
            begin
                yield
                nil
            rescue Interrupt, SystemExit
                raise
            rescue Exception => e
                if e.user_error?
                    io.print color(e.message, :bold, :red)
                else
                    do_display_exception(
                        io, e,
                        backtrace: backtrace,
                        skip_identical_backtraces: skip_identical_backtraces
                    )
                end
                e
            end
        elsif !e
            raise ArgumentError, "expected an exception object as no block was given"
        else
            do_display_exception(
                io, e,
                backtrace: backtrace,
                skip_identical_backtraces: skip_identical_backtraces
            )
            e
        end
    ensure
        Roby.app.filter_backtraces = old_filter_backtraces
    end

    def self.flatten_exception(e)
        result = [e].to_set

        if e.kind_of?(ExecutionException)
            result.merge(flatten_exception(e.exception))
        end

        if e.respond_to?(:each_original_exception)
            e.each_original_exception do |orig_e|
                result.merge(flatten_exception(orig_e))
            end
        end
        result
    end
end
