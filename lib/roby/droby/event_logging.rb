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

            # The amount of cycles pending in the {#event_logger}'s dump queue
            def log_queue_size
                event_logger.log_queue_size
            end
        end
    end
end


