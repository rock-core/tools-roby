# frozen_string_literal: true

module Roby
    module DRoby
        class NullEventLogger
            def log_timepoints?; end

            def dump(m, time, *args); end

            def dump_timepoint(m, time, *args); end

            def close; end

            def log_queue_size
                0
            end

            def dump_time
                0
            end

            def flush_cycle(m, *args); end
        end
    end
end
