require 'utilrb/logger'

# The main namespace for the Roby library. The namespace is divided as follows:
#
# [Roby] core namespace for the Roby kernel
# [Roby::Actions] basic tools for plan generation
# [Roby::Transactions] implementation of transactions. Transactions represent a
# change in the main plan, and can be distributed among different plan managers.
# [Roby::EventStructure] main namespace for event relations. The methods listed
# in the documentation of EventStructure are actually methods of Roby::EventGenerator
# [Roby::TaskStructure] main namespace for task relations. The methods listed in
# the documentation of TaskStructure are actually methods of Roby::Task
module Roby
    class DistributedObject; end
    class PlanObject < DistributedObject; end
    class Plan < DistributedObject; end
    class Control; end
    class EventGenerator < PlanObject; end
    class Task < PlanObject; end

    extend Logger::Root('Roby', Logger::WARN)
end

require 'concurrent'
require 'backports/2.4.0/regexp/match'
require 'backports/2.4.0/hash/transform_values'
require 'backports/2.5.0/hash/slice'
require 'backports/2.5.0/hash/transform_keys'
require 'roby/backports'

require 'pp'
require 'thread'
require 'set'
require 'yaml'
require 'pastel'
require 'hooks'
require 'fcntl'
require 'metaruby/dsls'
require 'utilrb/object/attribute'
require 'utilrb/object/address'
require 'utilrb/module/ancestor_p'
require 'utilrb/kernel/options'
require 'utilrb/module/attr_enumerable'
require 'utilrb/module/attr_predicate'
require 'utilrb/module/include'
require 'utilrb/kernel/arity'
require 'utilrb/exception/full_message'
require 'utilrb/unbound_method/call'
require 'metaruby'

require 'roby/version'
require 'roby/droby/marshallable'
require 'roby/droby/event_logging'

require 'roby/support'
require 'roby/disposable'
require 'roby/promise'
require 'roby/hooks'
require 'roby/distributed_object'
require 'roby/standard_errors'
require 'roby/exceptions'

require 'roby/relations'
require 'roby/plan'
require 'roby/executable_plan'
require 'roby/template_plan'

require 'roby/transaction'
require 'roby/transaction/proxying'

require 'roby/models/plan_object'
require 'roby/plan_object'
require 'roby/event_generator'
require "roby/event_structure/signal"
require "roby/event_structure/forwarding"
require "roby/event_structure/causal_link"
require "roby/event_structure/precedence"
require "roby/event_structure/temporal_constraints"

require 'roby/queries'
require 'roby/event'
require 'roby/filter_generator'
require 'roby/and_generator'
require 'roby/or_generator'
require 'roby/until_generator'
require 'roby/models/arguments'
require 'roby/models/task_service'
require 'roby/models/task'
require 'roby/models/task_event'
require 'roby/task_event'
require 'roby/task_event_generator'
require 'roby/task_arguments'
require 'roby/task_service'
require 'roby/task'
require "roby/task_structure/conflicts"
require "roby/task_structure/dependency"
require "roby/task_structure/error_handling"
require "roby/task_structure/executed_by"
require "roby/task_structure/planned_by"

require 'roby/tasks/aggregator'
require 'roby/tasks/parallel'
require 'roby/tasks/sequence'
require 'roby/event_constraints'

require 'roby/transaction/plan_object_proxy'
require 'roby/transaction/event_generator_proxy'
require 'roby/transaction/task_event_generator_proxy'
require 'roby/transaction/task_proxy'

require 'roby/plan_service'
require 'roby/transaction/plan_service_proxy'

require 'roby/decision_control'
require 'roby/schedulers/null'
require 'roby/execution_engine'
begin
    require 'gctools/oobgc'
    Roby::ExecutionEngine.use_oob_gc = true
rescue LoadError
end
require 'roby/app'
require 'roby/state'
require 'roby/singletons'

require 'roby/interface/job'
require 'roby/robot'
require 'roby/actions'
require 'roby/coordination'

require 'roby/droby/enable'
require 'roby/custom_require'

module Roby
    BIN_DIR = File.expand_path(File.join("..", "bin"), __dir__)
end
