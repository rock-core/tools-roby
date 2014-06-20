require 'roby/test/self'

class TC_Robot < Minitest::Test
    def setup
        super
        @plan = Roby.app.plan # The Robot interface can only work on the singleton Roby app
    end

    def test_action_from_model_no_match
        task_m = Roby::Task.new_submodel
        planner = flexmock
        planner.should_receive(:find_all_actions_by_type).once.
            with(task_m).and_return([])
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_raises(ArgumentError) { Robot.action_from_model(task_m) }
    end
    def test_action_from_model_one_match
        task_m = Roby::Task.new_submodel
        planner = flexmock
        planner.should_receive(:find_all_actions_by_type).once.
            with(task_m).and_return([action = flexmock(:name => 'A')])
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_equal [planner, action], Robot.action_from_model(task_m)
    end
    def test_action_from_model_multiple_matches
        task_m = Roby::Task.new_submodel
        planner = flexmock
        planner.should_receive(:find_all_actions_by_type).once.
            with(task_m).and_return([flexmock(:name => 'A'), flexmock(:name => 'A')])
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_raises(ArgumentError) { Robot.action_from_model(task_m) }
    end
    def test_prepare_action_with_model
        task_t = Roby::Task.new_submodel
        task, planner_task = task_t.new, task_t.new
        task.planned_by planner_task
        planner = flexmock
        planning_method = flexmock(:plan_pattern => task)
        flexmock(Roby.app).should_receive(:action_from_model).with(task_t).and_return([planner, planning_method])

        assert_equal [task, planner_task], Robot.prepare_action(Roby.app.plan, task_t)
        assert_same Roby.app.plan, task.plan
    end
    def test_prepare_action_passes_arguments
        arguments = {:id => 10}

        task_t = Roby::Task.new_submodel
        task, planner_task = task_t.new, task_t.new
        task.planned_by planner_task
        planner = flexmock
        planning_method = flexmock
        planning_method.should_receive(:plan_pattern).with(arguments).once.and_return(task)
        flexmock(Roby.app).should_receive(:action_from_model).with(task_t).and_return([planner, planning_method])

        assert_equal [task, planner_task], Robot.prepare_action(Roby.app.plan, task_t, arguments)
        assert_same Roby.app.plan, task.plan
    end
end

