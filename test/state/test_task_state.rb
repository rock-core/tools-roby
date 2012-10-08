$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock/test_unit'
require 'roby/state'

class TC_TaskState < Test::Unit::TestCase
    include Roby::SelfTest

    def test_task_state_model_is_attached_to_task
        task_model = Class.new(Roby::Task)
        task_state = task_model.state
        assert_same task_model, task_state.task_model
    end

    def test_task_state_model_refines_parent_task_model
        parent_model = Class.new(Roby::Task)
        child_model = Class.new(parent_model)

        task_state = child_model.state
        assert_same parent_model.state, task_state.superclass
    end
end

