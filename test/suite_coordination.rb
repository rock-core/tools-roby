$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'coordination/test_task_base'
require 'coordination/models/test_task'

require 'coordination/test_task_script'
require 'coordination/test_task_state_machine'
require 'coordination/test_script'
require 'coordination/test_action_script'
require 'coordination/test_fault_handler'
require 'coordination/test_fault_response_table'
require 'coordination/test_action_state_machine'

