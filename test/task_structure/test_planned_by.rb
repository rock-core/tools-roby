require 'roby/test/self'

class TC_PlannedBy < Minitest::Test
    PlannedBy = Roby::TaskStructure::PlannedBy
    def test_replace
	task, p1, p2 = prepare_plan add: 3
	task.planned_by p1

	assert_raises(ArgumentError) { task.planned_by p2 }
	assert(task.child_object?(p1, PlannedBy))
	assert(!task.child_object?(p2, PlannedBy))

	task.planned_by p2, replace: true
	assert(!task.child_object?(p1, PlannedBy))
	assert(task.child_object?(p2, PlannedBy))
    end

    def test_it_does_not_assign_the_error_to_any_parent
        plan.add_permanent(root = Roby::Task.new)
	task = root.depends_on(Roby::Task.new)
        planner = task.planned_by(Roby::Test::Tasks::Simple.new)
	planner.start!

        spy = flexmock(plan.execution_engine) do |s|
            s.should_receive(:propagate_exceptions).with([])
            s.should_receive(:propagate_exceptions).
                with(->(e) { e.first.first.exception.kind_of?(Exception) && e.first.last == [] })
        end
        inhibit_fatal_messages do
            assert_raises(PlanningFailedError) { planner.failed! }
        end
    end

    def test_check
	task = Roby::Task.new
	planner = Roby::Test::Tasks::Simple.new
	task.planned_by planner
	plan.add_permanent(task)

	assert_equal([], plan.check_structure.to_a)
	planner.start!
	assert_equal([], plan.check_structure.to_a)
	planner.success!
	assert_equal([], plan.check_structure.to_a)

	task.remove_planning_task planner
	planner = Roby::Test::Tasks::Simple.new
	task.planned_by planner

	assert_equal([], plan.check_structure.to_a)
	planner.start!
	assert_equal([], plan.check_structure.to_a)
        error = inhibit_fatal_messages do
            assert_raises(PlanningFailedError) { planner.failed! }
        end

        assert(error, "no PlanningFailedError generated while one was expected")
        error = error.exception
	assert_equal(planner, error.planning_task)
	assert_equal(task, error.planned_task)

        # Verify that the formatting works fine
        PP.pp(error, "")
    end

    def test_as_plan
        model = Tasks::Simple.new_submodel do
            def self.as_plan
                new(id: 10)
            end
        end
        root = prepare_plan add: 1, model: Tasks::Simple
        agent = root.planned_by(model)
        assert_kind_of model, agent
        assert_equal 10, agent.arguments[:id]
    end

    def test_failure_on_abstract_task_leads_to_task_removal
	Roby::ExecutionEngine.logger.level = Logger::FATAL + 1
	task = Roby::Task.new
	planner = Roby::Test::Tasks::Simple.new
        task.planned_by planner
        plan.add_permanent(task)

        planner.start!
        assert !task.finalized?
        assert_raises(PlanningFailedError) { planner.failed! }
        assert task.finalized?
    end
end

