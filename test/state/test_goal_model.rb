require 'roby/test/self'
require 'roby/state'

class TC_StateModel < Minitest::Test
    def test_it_calls_to_global_variable_model_on_assigned_values
        mock = flexmock
        mock.should_receive(:to_goal_variable_model).once.
            and_return(obj = Object.new)

        goal_model = Roby::GoalModel.new
        goal_model.pose.position = mock
        assert_same obj, goal_model.pose.position
    end

    def test_it_creates_GoalModel_children
        goal_model = GoalModel.new
        assert_kind_of GoalModel, goal_model.child
    end

    def test_it_typechecks_assigned_goal_variables
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

    def test_it_accepts_a_superclass
        parent = Roby::GoalModel.new
        child = Roby::GoalModel.new(nil, parent)
        assert_same parent, child.superclass
    end

    def test_it_follows_the_state_model_if_given_one
        goal_model = Roby::GoalModel.new(s = Roby::StateModel.new)
        s.pose.position = Object

        var = Roby::GoalVariableModel.new
        assert_raises(ArgumentError) { goal_model.pose = var }
        assert_raises(ArgumentError) { goal_model.another_var = var }
        goal_model.pose.position = var
    end

    def test_resolve_goals
        obj = flexmock
        position = flexmock(OpenStructModel::Variable.new)
        position.should_receive(:call).with(obj).and_return(10)
        position.should_receive(:to_goal_variable_model).and_return(position)
        value = flexmock(OpenStructModel::Variable.new)
        value.should_receive(:call).with(obj).and_return(20)
        value.should_receive(:to_goal_variable_model).and_return(value)

        m = Roby::GoalModel.new
        m.pose.position = position
        m.value = value
        g = Roby::GoalSpace.new(m)

        m.resolve_goals(obj, g)

        assert_equal 10, g.pose.position
        assert_equal 20, g.value
    end
end

