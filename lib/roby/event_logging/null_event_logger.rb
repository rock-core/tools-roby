# frozen_string_literal: true

module Roby
    module EventLogging
        # An object that matches the event logger's interface but does nothing
        class NullEventLogger
            def log_timepoints?; end

            def dump(name, time, *args); end

            def dump_timepoint(name, time, *args); end

            def close; end

            def log_queue_size
                0
            end

            def dump_time
                0
            end

            def flush_cycle(name, *args); end
        end
    end

    module DRoby
        # Backward-compatible reference to EventLogging::NullEventLogger
        NullEventLogger = Roby::EventLogging::NullEventLogger
    end
end
