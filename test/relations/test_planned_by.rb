$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'

class TC_PlannedBy < Test::Unit::TestCase
    include Roby::Test

    PlannedBy = Roby::TaskStructure::PlannedBy
    def test_check
	task = Roby::Task.new
	planner = Roby::Test::SimpleTask.new
	task.planned_by planner
	plan.permanent(task)

	assert_equal([], PlannedBy.check_planning(plan))
	planner.start!
	assert_equal([], PlannedBy.check_planning(plan))
	planner.success!
	assert_equal([], PlannedBy.check_planning(plan))

	task.remove_planning_task planner
	planner = Roby::Test::SimpleTask.new
	task.planned_by planner

	assert_equal([], PlannedBy.check_planning(plan))
	planner.start!
	assert_equal([], PlannedBy.check_planning(plan))
	planner.failed!

	error = *PlannedBy.check_planning(plan)
	assert_kind_of(Roby::PlanningFailedError, error)
	assert_equal(planner, error.planning_task)
	assert_equal(task, error.planned_task)
	assert_equal(planner.terminal_event, error.error)
    end
end

