module Roby
    ROBY_LIB_DIR  = File.expand_path( File.join(File.dirname(__FILE__)) )
    ROBY_ROOT_DIR = File.expand_path( File.join(ROBY_LIB_DIR, '..') )

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
require 'roby/query'
require 'roby/control'

require 'roby/propagation'
require 'roby/relations/events'
require 'roby/relations/hierarchy'
require 'roby/relations/planned_by'
require 'roby/relations/executed_by'
require 'roby/relations/ensured'

require 'roby/state'
require 'roby/interface'

require 'roby/distributed/protocol'

