$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock/test_unit'
require 'roby/state'

class TC_StateInTask < Test::Unit::TestCase
    def test_state_model_gets_inherited
        task_model = Roby::Task.new_submodel
        assert_same Roby::Task.state, task_model.state.superclass
    end

    def test_task_state_space_gets_model_from_task
        task_model = Roby::Task.new_submodel
        task = task_model.new
        assert_same task.state.model, task.model.state
    end

    def test_resolve_state_sources
        task_model = Roby::Task.new_submodel
        source_model = flexmock
        source_model.should_receive(:to_state_variable_model).
            and_return do |field, name|
                result = Roby::StateVariableModel.new(field, name)
                result.data_source = source_model
                result
            end
        task_model.state.pose.position = source_model

        task = task_model.new
        source_model.should_receive(:resolve).with(task).once.
            and_return(source = Object.new)
        task.resolve_state_sources
        assert_same source, task.state.data_sources.pose.position
    end

    def test_goal_model_gets_inherited
        task_model = Roby::Task.new_submodel
        assert_same Roby::Task.goal, task_model.goal.superclass
    end

    def test_goal_space_gets_model_from_task_model
        task_model = Roby::Task.new_submodel
        task = task_model.new
        assert_same task.goal.model, task.model.goal
    end

    def test_goal_model_uses_state_model
        task_model = Roby::Task.new_submodel
        assert_same task_model.state, task_model.goal.model
    end
end

