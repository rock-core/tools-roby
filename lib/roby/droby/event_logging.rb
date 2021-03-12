# frozen_string_literal: true

module Roby
    module DRoby
        # Mixin to add event-logging related functionality to a class
        #
        # The class must provide a #event_logger object. It must be non-nil, and
        # can be initialized with {NullEventLogger} for a no-op logger
        module EventLogging
            # Log an event on the underlying logger
            def log(m, *args)
                event_logger.dump(m, Time.now, args)
            end

            # Log a timepoint on the underlying logger
            def log_timepoint(name)
                return unless event_logger.log_timepoints?

                current_thread = Thread.current
                event_logger.dump_timepoint(
                    :timepoint, Time.now,
                    [current_thread.droby_id, current_thread.name, name]
                )
            end

            # Run a block within a timepoint group
            def log_timepoint_group(name)
                return yield unless event_logger.log_timepoints?

                log_timepoint_group_start(name)
                yield
            ensure
                log_timepoint_group_end(name)
            end

            # Log a timepoint on the underlying logger
            #
            # The logger will NOT do any validation of the group start/end
            # pairing at logging time. This is done at replay time
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
            # The logger will NOT do any validation of the group start/end
            # pairing at logging time. This is done at replay time
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

            def log_flush_cycle(m, *args)
                event_logger.flush_cycle(m, Time.now, args)
            end
        end
    end
end
