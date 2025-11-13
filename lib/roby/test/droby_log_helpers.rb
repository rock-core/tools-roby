# frozen_string_literal: true

require "roby/droby/logfile"
require "roby/droby/logfile/writer"
require "roby/event_logging/droby_event_logger"

module Roby
    module Test
        # Helpers to create droby log files for log-related tests
        module DRobyLogHelpers
            # Create an event log file
            #
            # @param [String] path path to the file to create. If relative, it
            #   is placed in an automatically created temporary directory
            #
            # @overload droby_create_event_log(path)
            #    Create the log file and returns the event logger that allows to set
            #    it up.
            #
            #    @return [DRoby::EventLogger]
            #
            # @overload droby_create_event_log(path) { |event_logger| }
            #    Create the log file and let you add events to it. Close the
            #    file on block return
            #
            #    @yieldparam [DRoby::EventLogger]
            #    @return [String] the file's full path
            def droby_create_event_log(path)
                unless path.start_with?("/")
                    dir = make_tmpdir
                    path = File.join(dir, path)
                end

                @__event_log_path = path
                io = File.open(path, "w")
                logfile = DRoby::Logfile::Writer.new(io)
                @__event_logger = EventLogging::DRobyEventLogger.new(logfile)
                @__cycle_start = Time.now
                @__cycle_index = 0

                return @__event_logger unless block_given?

                begin
                    yield
                    path
                ensure
                    droby_close_event_log
                end
            end

            # Add an event to the current event cycle
            def droby_write_event(method_name, *args, time: Time.now)
                @__event_logger.dump(method_name, time, args)
            end

            # The event logger last created by {#droby_create_event_log}
            #
            # This is reset with {#droby_close_event_log}
            def droby_current_event_logger
                @__event_logger
            end

            # Path to the last log file created by {#droby_create_event_log}
            #
            # This is reset with {#droby_close_event_log}
            def droby_event_log_path
                @__event_log_path
            end

            # Close the last event log (and file) created by {#droby_create_event_log}
            def droby_close_event_log
                droby_flush_cycle
                @__event_logger.close
                @__event_logger = nil
            end

            # Finish the current cycle's log and flush it to file
            def droby_flush_cycle
                t = Time.now
                @__event_logger.flush_cycle(
                    :cycle_end, t,
                    [{ start: [@__cycle_start.tv_sec, @__cycle_start.tv_usec],
                       end: (t - @__cycle_start),
                       cycle_index: (@__cycle_index += 1) }]
                )

                @__cycle_start = t
            end
        end
    end
end
