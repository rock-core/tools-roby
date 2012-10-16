$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock/test_unit'
require 'roby/state'

class TC_StateModel < Test::Unit::TestCase
    include Roby::SelfTest

    def test_assign_goal_variable_calls_to_goal_variable_model
        mock = flexmock
        mock.should_receive(:to_goal_variable_model).once.
            and_return(obj = Object.new)

        goal_model = Roby::GoalModel.new
        goal_model.pose.position = mock
        assert_same obj, goal_model.pose.position
    end

    def test_goal_model_children_are_goal_models
        goal_model = GoalModel.new
        assert_kind_of GoalModel, goal_model.child
    end

    def test_assign_goal_variable_does_typechecking
        goal_model = GoalModel.new
        assert_raises(ArgumentError) { goal_model.pose.position = Object.new }
    end

    def test_proc_to_global_variable_model
        prc = proc { |task| }
        var = prc.to_goal_variable_model(obj = Object.new, "field")
        assert_same prc, var.reader
        assert_equal obj, var.field
        assert_equal "field", var.name
    end

    def test_goal_model_accepts_a_superclass
        parent = Roby::GoalModel.new
        child = Roby::GoalModel.new(parent)
        assert_same parent, child.superclass
    end

    def test_goal_model_follows_state_model_if_given_one
        goal_model = Roby::GoalModel.new
        s = goal_model.state_model = Roby::StateModel.new
        s.pose.position = Object

        var = Roby::GoalVariableModel.new
        assert_raises(ArgumentError) { goal_model.pose = var }
        assert_raises(ArgumentError) { goal_model.another_var = var }
        goal_model.pose.position = var
    end
end

