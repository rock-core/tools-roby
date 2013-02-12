$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'

class TC_PlannedBy < Test::Unit::TestCase
    include Roby::SelfTest

    PlannedBy = Roby::TaskStructure::PlannedBy
    def test_replace
	task, p1, p2 = prepare_plan :add => 3
	task.planned_by p1

	assert_raises(ArgumentError) { task.planned_by p2 }
	assert(task.child_object?(p1, PlannedBy))
	assert(!task.child_object?(p2, PlannedBy))

	assert_nothing_raised { task.planned_by p2, :replace => true }
	assert(!task.child_object?(p1, PlannedBy))
	assert(task.child_object?(p2, PlannedBy))
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
        inhibit_fatal_messages do
            assert_raises(PlanningFailedError) { planner.failed! }
        end

	errors = plan.check_structure.to_a
        error = errors.find { |err| err.first.exception.kind_of?(Roby::PlanningFailedError) }
        assert(error, "no PlanningFailedError generated while one was expected")
        error = error.first.exception
	assert_equal(planner, error.failed_task, "failed task was expected to be the planner, but was #{error.failed_task}")
	assert_equal(task, error.planned_task)
	assert_equal(planner.terminal_event, error.failed_event)

        # Verify that the formatting works fine
        PP.pp(error, "")

	# Clear the planned task to make test teardown happy
	plan.remove_object(task)
    end

    def test_as_plan
        model = Tasks::Simple.new_submodel do
            def self.as_plan
                new(:id => 10)
            end
        end
        root = prepare_plan :add => 1, :model => Tasks::Simple
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
        engine.run
        assert !task.finalized?
        engine.wait_one_cycle
        engine.execute { planner.failed! }
        engine.wait_one_cycle
        assert task.finalized?
    end
end

