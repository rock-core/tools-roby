# frozen_string_literal: true

module Roby
    module EventLogging
        # An object that allows to dispatch logged events to multiple loggers
        #
        # It is used by default by {Plan} and {ExecutionEngine}
        class AggregateEventLogger
            def initialize
                @loggers = []
            end

            # Add a logger to the aggregate
            #
            # @return [#dispose] a disposable that allows to remove the logger
            def add(logger)
                @loggers << logger
                @log_timepoints ||= logger.log_timepoints?

                Roby.disposable do
                    remove(logger)
                end
            end

            # @api private
            #
            # Remove the logger from the aggregate
            #
            # Do not use this directly. Use the disposable returned from {#add} instead.
            # This method's interface may change without notice
            def remove(logger)
                @loggers.delete(logger)
                @log_timepoints = @loggers.any?(&:log_timepoints?)
            end

            # Whether timepoints should be logged at all
            def log_timepoints?
                @log_timepoints
            end

            # Dump a normal log event
            def dump(m, time, *args)
                @loggers.each { |l| l.dump(m, time, *args) }
            end

            # Dump a timepoint
            def dump_timepoint(m, time, *args)
                @loggers.each { |l| l.dump_timepoint(m, time, *args) }
            end

            def close
                @loggers.each(&:close)
            end

            def log_queue_size
                @loggers.map(&:log_queue_size).max
            end

            def dump_time
                @loggers.sum(&:dump_time)
            end

            def flush_cycle(m, *args)
                @loggers.each { _1.flush_cycle(m, *args) }
            end

            # Remove all of the current loggers and return them
            #
            # @return [Array<EventLogger>] the current loggers
            def clear
                current = @loggers.dup
                @loggers = []
                current
            end
        end
    end
end
