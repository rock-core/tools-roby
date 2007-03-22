module Roby
    class BasicObject; end
    class PlanObject < BasicObject; end
    class Plan < BasicObject; end
    class Control; end
    class EventGenerator < PlanObject; end
    class Task < PlanObject; end
end

require 'roby/support'
require 'roby/task'
require 'roby/event'

require 'roby/plan'
require 'roby/control'

require 'roby/propagation'
require 'roby/relations/events'
require 'roby/relations/hierarchy'
require 'roby/relations/planned_by'
require 'roby/relations/executed_by'
require 'roby/relations/ensured'

require 'roby/state'
require 'roby/control_interface'
require 'roby/query'

require 'roby/distributed/protocol'

