$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/tasks/simple'
require 'flexmock/test_unit'

require 'roby'
class TC_Robot < Test::Unit::TestCase
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

    def test_action_from_model_no_match
        task_m = Class.new(Roby::Task)
        planner = flexmock
        planner.should_receive(:find_all_actions_by_type).once.
            with(task_m).and_return([])
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_raises(ArgumentError) { Robot.action_from_model(task_m) }
    end
    def test_action_from_model_one_match
        task_m = Class.new(Roby::Task)
        planner = flexmock
        planner.should_receive(:find_all_actions_by_type).once.
            with(task_m).and_return([action = flexmock(:name => 'A')])
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_equal [planner, action], Robot.action_from_model(task_m)
    end
    def test_action_from_model_multiple_matches
        task_m = Class.new(Roby::Task)
        planner = flexmock
        planner.should_receive(:find_all_actions_by_type).once.
            with(task_m).and_return([flexmock(:name => 'A'), flexmock(:name => 'A')])
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_raises(ArgumentError) { Robot.action_from_model(task_m) }
    end
    def test_prepare_action_with_model
        task_t = Class.new(Roby::Task)
        task, planner_task = task_t.new, task_t.new
        task.planned_by planner_task
        planner = flexmock
        planning_method = flexmock(:plan_pattern => task)
        flexmock(Robot).should_receive(:action_from_model).with(task_t).and_return([planner, planning_method])

        assert_equal [task, planner_task], Robot.prepare_action(plan, task_t)
        assert_same plan, task.plan
    end
    def test_prepare_action_passes_arguments
        arguments = {:id => 10}

        task_t = Class.new(Roby::Task)
        task, planner_task = task_t.new, task_t.new
        task.planned_by planner_task
        planner = flexmock
        planning_method = flexmock
        planning_method.should_receive(:plan_pattern).with(arguments).once.and_return(task)
        flexmock(Robot).should_receive(:action_from_model).with(task_t).and_return([planner, planning_method])

        assert_equal [task, planner_task], Robot.prepare_action(plan, task_t, arguments)
        assert_same plan, task.plan
    end
end

