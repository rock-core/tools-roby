# frozen_string_literal: true

if !Qt::DateTime.method_defined?("toMSecsSinceEpoch")
    class Qt::DateTime
        def toMSecsSinceEpoch
            toTime_t * 1000 + time.msec
        end
    end
end
