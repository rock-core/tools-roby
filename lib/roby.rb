# The main namespace for the Roby library. The namespace is divided as follows:
#
# [Roby] core namespace for the Roby kernel
# [Roby::Distributed] parts that are very specific to distributed plan management
# [Roby::Actions] basic tools for plan generation
# [Roby::Transactions] implementation of transactions. Transactions represent a
# change in the main plan, and can be distributed among different plan managers.
# [Roby::EventStructure] main namespace for event relations. The methods listed
# in the documentation of EventStructure are actually methods of Roby::EventGenerator
# [Roby::TaskStructure] main namespace for task relations. The methods listed in
# the documentation of TaskStructure are actually methods of Roby::Task
module Roby
    class BasicObject; end
    class PlanObject < BasicObject; end
    class Plan < BasicObject; end
    class Control; end
    class EventGenerator < PlanObject; end
    class Task < PlanObject; end
end

require 'drb'
require 'utilrb/weakref'
require 'pp'
require 'thread'
require 'set'
require 'yaml'
require 'metaruby/dsls'
require 'utilrb/value_set'
require 'utilrb/object/attribute'
require 'utilrb/module/ancestor_p'
require 'utilrb/kernel/options'
require 'utilrb/module/attr_enumerable'
require 'utilrb/module/attr_predicate'
require 'utilrb/module/include'
require 'utilrb/module/is_singleton'
require 'utilrb/kernel/arity'
require 'utilrb/kernel/swap'
require 'utilrb/exception/full_message'
require 'utilrb/unbound_method/call'
require 'metaruby'

require 'roby/config'
require 'roby/support'
require 'roby/basic_object'
require 'roby/standard_errors'
require 'roby/exceptions'

require 'roby/distributed/base'

begin
    require 'roby_bgl'
rescue LoadError
    STDERR.puts "Cannot require Roby's roby_bgl C extension"
    STDERR.puts "If you are using Rock, it should have been built automatically."
    STDERR.puts "Run"
    STDERR.puts "  amake roby"
    STDERR.puts "and try again"
    exit 1
end

require 'roby/graph'
require 'roby/relations'

require 'roby/queries'
require 'roby/plan-object'
require 'roby/event'
require 'roby/event_generator'
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
require 'roby/task'
require 'roby/plan_service'
require 'roby/tasks/aggregator'
require 'roby/tasks/parallel'
require 'roby/tasks/sequence'
require 'roby/event_constraints'

require 'roby/relations/conflicts'
require 'roby/relations/ensured'
require 'roby/relations/error_handling'
require 'roby/relations/events'
require 'roby/relations/executed_by'
require 'roby/relations/dependency'
require 'roby/relations/influence'
require 'roby/relations/planned_by'
require 'roby/relations/temporal_constraints'

require 'roby/plan'
require 'roby/transactions/proxy'
require 'roby/transactions'

begin
    require 'roby_marshalling'
rescue LoadError
    STDERR.puts "Cannot require Roby's roby_marshalling C extension"
    STDERR.puts "If you are using Rock, it should have been built automatically."
    STDERR.puts "Run"
    STDERR.puts "  amake roby"
    STDERR.puts "and try again"
    exit 1
end
require 'roby/distributed/remote_object_manager'
require 'roby/distributed/peer'
require 'roby/distributed/protocol'

require 'roby/decision_control'
require 'roby/execution_engine'
require 'roby/app'
require 'roby/state'
require 'roby/singletons'
require 'roby/log'

require 'roby/interface/job'
require 'roby/robot'
require 'roby/actions'
require 'roby/coordination'

