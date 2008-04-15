# The main namespace for the Roby library. The namespace is divided as follows:
#
# [Roby] core namespace for the Roby kernel
# [Roby::Distributed] parts that are very specific to distributed plan management
# [Roby::Planning] basic tools for plan generation
# [Roby::Transactions] implementation of transactions
# [Roby::EventStructure] event relations
# [Roby::TaskStructure] task relations
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
require 'roby/standard_errors'

require 'roby/plan'
require 'roby/query'
require 'roby/control'
require 'roby/decision_control'

require 'roby/propagation'
require 'roby/relations/events'
require 'roby/relations/hierarchy'
require 'roby/relations/influence'
require 'roby/relations/planned_by'
require 'roby/relations/executed_by'
require 'roby/relations/ensured'

require 'roby/state'
require 'roby/interface'

require 'roby/distributed/protocol'

require 'roby/app'
