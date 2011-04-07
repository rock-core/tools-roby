$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'

class TC_PlannedBy < Test::Unit::TestCase
    include Roby::Test

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
	planner.failed!

	errors = plan.check_structure.to_a
        assert_equal 1, errors.size
        error = errors.first.first.exception
	assert_kind_of(Roby::PlanningFailedError, error)
	assert_equal(planner, error.failed_task)
	assert_equal(task, error.planned_task)
	assert_equal(planner.terminal_event, error.failed_event)

	# Clear the planned task to make test teardown happy
	plan.remove_object(task)
    end

    def test_as_plan
        model = Class.new(Tasks::Simple) do
            def self.as_plan
                new(:id => 10)
            end
        end
        root = prepare_plan :add => 1, :model => Tasks::Simple
        agent = root.planned_by(model)
        assert_kind_of model, agent
        assert_equal 10, agent.arguments[:id]
    end
end

