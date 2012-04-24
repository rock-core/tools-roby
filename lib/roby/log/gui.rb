require 'Qt4'

if !Qt::DateTime.method_defined?('toMSecsSinceEpoch')
    class Qt::DateTime
        def toMSecsSinceEpoch
            toTime_t * 1000 + time.msec
        end
    end
end

require 'roby/log/gui/log_display'
require 'roby/log/gui/plan_rebuilder_widget'
require 'roby/log/gui/styles'
require 'roby/log/gui/chronicle'
require 'roby/log/gui/object_info_view'
require 'roby/log/gui/relations_view/relations_view'
require 'roby/log/gui/stepping.rb'
