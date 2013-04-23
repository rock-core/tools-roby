# The main namespace for the Roby library. The namespace is divided as follows:
#
# [Roby] core namespace for the Roby kernel
# [Roby::Distributed] parts that are very specific to distributed plan management
# [Roby::Planning] basic tools for plan generation
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
require 'utilrb/value_set'
require 'utilrb/object/attribute'
require 'utilrb/module/ancestor_p'
require 'utilrb/kernel/options'
require 'utilrb/module/attr_enumerable'
require 'utilrb/module/attr_predicate'
require 'utilrb/module/include'
require 'utilrb/kernel/arity'
require 'utilrb/kernel/swap'
require 'utilrb/exception/full_message'
require 'utilrb/unbound_method/call'
require 'metaruby'

require 'roby/config.rb'
require 'roby/support.rb'
require 'roby/basic_object.rb'
require 'roby/standard_errors.rb'
require 'roby/exceptions.rb'

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

require 'roby/graph.rb'
require 'roby/relations.rb'

require 'roby/plan-object.rb'
require 'roby/event.rb'
require 'roby/models/arguments'
require 'roby/models/task_service'
require 'roby/models/task'
require 'roby/models/task_event'
require 'roby/task_event'
require 'roby/task_event_generator'
require 'roby/task_arguments'
require 'roby/task'
require 'roby/task_statemachine.rb'
require 'roby/plan_service.rb'
require 'roby/tasks/aggregator'
require 'roby/tasks/parallel'
require 'roby/tasks/sequence'
require 'roby/event_constraints.rb'

require 'roby/relations/conflicts.rb'
require 'roby/relations/ensured.rb'
require 'roby/relations/error_handling.rb'
require 'roby/relations/events.rb'
require 'roby/relations/executed_by.rb'
require 'roby/relations/dependency.rb'
require 'roby/relations/influence.rb'
require 'roby/relations/planned_by.rb'
require 'roby/relations/temporal_constraints'

require 'roby/task_index.rb'
require 'roby/plan.rb'
require 'roby/transactions/proxy.rb'
require 'roby/transactions.rb'
require 'roby/query.rb'

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
require 'roby/distributed/peer'
require 'roby/distributed/protocol'

require 'roby/decision_control.rb'
require 'roby/execution_engine.rb'
require 'roby/app.rb'
require 'roby/state.rb'
require 'roby/singletons'
require 'roby/log'

require 'roby/robot.rb'
require 'roby/actions'
require 'roby/planning.rb'
require 'roby/task_scripting.rb'

