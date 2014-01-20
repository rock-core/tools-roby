$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))

require 'test_bgl'
require 'test_relations'
require 'test_event'
require 'test_task'
require 'test_task_arguments'
require 'test_task_service'
require 'state/test_goal_model'
require 'state/test_open_struct'
require 'state/test_state_events'
require 'state/test_state_model'
require 'state/test_state_space'
require 'state/test_task'
require 'test_event_constraints'
require 'suite_models'

require 'test_execution_engine'
require 'test_execution_exception'

require 'test_plan'
require 'test_transactions'
require 'test_transactions_proxy'

require 'tasks/test_thread_task'
require 'tasks/test_external_process'

require 'schedulers/test_basic'
require 'schedulers/test_temporal'

# require 'test_testcase'

require 'suite_actions'
require 'suite_relations'
require 'suite_queries'
require 'suite_state'
require 'suite_coordination'

require 'suite_interface'
require 'test_log'

