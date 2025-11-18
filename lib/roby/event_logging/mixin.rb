# frozen_string_literal: true

module Roby
    module EventLogging
        # Mixin to add event-logging related functionality to a class
        #
        # The class must provide a #event_logger object. It must be non-nil, and
        # can be initialized with {NullEventLogger} for a no-op logger
        module Mixin
            # Log an event
            #
            # Events are logged with a name, a timestamp and arbitrary arguments
            def log(name, *args)
                event_logger.dump(name, Time.now, args)
            end

            # Log a timepoint
            #
            # Timepoints are saved as :timepoint events, with a timestamp,
            # a reference on the thread that generated the timepoint and the timepoint
            # name
            def log_timepoint(name)
                return unless event_logger.log_timepoints?

                current_thread = Thread.current
                event_logger.dump_timepoint(
                    :timepoint, Time.now,
                    [current_thread.droby_id, current_thread.name, name]
                )
            end

            # Log a timepoint group
            #
            # Timepoint groups are zones of code that are gated with two timepoints,
            # a start timepoint #{name}_start and an end timepoint (#{name}_end).
            # This is used during analysis to show duration of blocks of code.
            #
            # This method will emit the start timepoint, yield and then emit
            # the end timepoint
            #
            # @see log_timepoint_group_start log_timepoint_group_end
            def log_timepoint_group(name)
                return yield unless event_logger.log_timepoints?

                log_timepoint_group_start(name)
                yield
            ensure
                log_timepoint_group_end(name)
            end

            # Start a timepoint group
            #
            # Timepoint groups are zones of code that are gated with two timepoints,
            # a start timepoint #{name}_start and an end timepoint (#{name}_end).
            # This is used during analysis to show duration of blocks of code.
            #
            # This emits the start timepoint. Client code is expected to ensure
            # proper pairing, the runtime code won't do any validation. Validation
            # is only performed at replay time
            #
            # @see log_timepoint_group log_timepoint_group_end
            def log_timepoint_group_start(name)
                return unless event_logger.log_timepoints?

                current_thread = Thread.current
                event_logger.dump_timepoint(
                    :timepoint_group_start, Time.now,
                    [current_thread.droby_id, current_thread.name, name]
                )
            end

            # End a timepoint group
            #
            # Timepoint groups are zones of code that are gated with two timepoints,
            # a start timepoint #{name}_start and an end timepoint (#{name}_end).
            # This is used during analysis to show duration of blocks of code.
            #
            # This emits the start timepoint. Client code is expected to ensure
            # proper pairing, the runtime code won't do any validation. Validation
            # is only performed at replay time
            #
            # @see log_timepoint_group log_timepoint_group_start
            def log_timepoint_group_end(name)
                return unless event_logger.log_timepoints?

                current_thread = Thread.current
                event_logger.dump_timepoint(
                    :timepoint_group_end, Time.now,
                    [current_thread.droby_id, current_thread.name, name]
                )
            end

            # The amount of cycles pending in the {#event_logger}'s dump queue
            def log_queue_size
                event_logger.log_queue_size
            end

            # Announce the last event of a cycle
            #
            # This is used for loggers that are cycle-based (e.g. the DRobyEventLogger)
            # so that it adds the given event and then save the whole cycle to I/O
            def log_flush_cycle(name, *args)
                event_logger.flush_cycle(name, Time.now, args)
            end
        end
    end

    module DRoby
        # Backward-compatible reference to EventLogging::Mixin
        EventLogging = Roby::EventLogging::Mixin
    end
end
