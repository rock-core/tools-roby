module Roby
    module DRoby
        class NullEventLogger
            def dump(m, time, *args)
            end

            def close
            end

            def log_queue_size
                0
            end

            def dump_time
                0
            end
        end
    end
end
