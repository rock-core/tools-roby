require 'roby/test/self'

if ENV['TEST_LOG_LEVEL']
    Roby.logger.level = Logger.const_get(ENV['TEST_LOG_LEVEL'])
elsif ENV['TEST_ENABLE_COVERAGE'] == '1' || rand > 0.5
    null_io = File.open('/dev/null', 'w')
    current_formatter = Roby.logger.formatter
    Roby.warn "running tests with logger in DEBUG mode"
    Roby.logger = Logger.new(null_io)
    Roby.logger.level = Logger::DEBUG
    Roby.logger.formatter = current_formatter
else
    Roby.warn "running tests with logger in FATAL mode"
    Roby.logger.level = Logger::FATAL + 1
end

require './test/test_event_generator'
require './test/test_or_generator'
require './test/test_and_generator'
require './test/test_exceptions'
require './test/test_plan_object'
require './test/test_task'
require './test/test_task_arguments'
require './test/test_task_service'
require './test/test_standard_errors'
require './test/state/test_goal_model'
require './test/state/test_open_struct'
require './test/state/test_state_events'
require './test/state/test_state_model'
require './test/state/test_state_space'
require './test/state/test_task'
require './test/test_event_constraints'
require './test/suite_models'

require './test/test_execution_engine'
require './test/test_execution_exception'

require './test/test_plan'
require './test/test_executable_plan'
require './test/test_plan_service'
require './test/test_transactions'
require './test/test_transactions_proxy'

require './test/tasks/test_virtual'
require './test/tasks/test_thread_task'
require './test/tasks/test_external_process'

require './test/schedulers/test_state'
require './test/schedulers/test_basic'
require './test/schedulers/test_temporal'

# require 'test_testcase'

require './test/test_app'
require './test/suite_app'
require './test/suite_actions'
require './test/suite_relations'
require './test/suite_queries'
require './test/suite_state'
require './test/suite_coordination'

require './test/suite_interface'
require './test/test_log'

