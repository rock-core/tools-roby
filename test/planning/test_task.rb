$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/planning'

require 'flexmock'
require 'roby/test/tasks/simple_task'

class TC_PlanningTask < Test::Unit::TestCase
    include Roby::Planning
    include Roby::Test

    def planning_task_result(planning_task)
        assert(planning_task)
	plan.permanent(planning_task)
	planning_task.start! if planning_task.pending?
	planning_task.thread.join
	process_events
	assert(planning_task.success?, planning_task.terminal_event.context)
	planning_task.planned_task
    end

    def test_planning_task_one_shot
	result_task = SimpleTask.new
	planner = Class.new(Planning::Planner) do
	    method(:task) do
		raise arguments.to_s unless arguments[:bla] == 42
		raise arguments.to_s unless arguments[:blo] == 84
		raise arguments.to_s unless arguments[:context] == [42]
		result_task
	    end
	end

	planning_task = PlanningTask.new(:planner_model => planner, :method_name => :task,
				:method_options => { :bla => 42 },
				:blo => 84)
	plan.insert(planned_task = Task.new)
	planned_task.planned_by planning_task

	planning_task.start!(42)
	FlexMock.use do |mock|
	    planning_task.on(:success) do
	        mock.planned_task(planning_task.planned_task)
		planning_task.planned_task.start!
	    end
	    mock.should_receive(:planned_task).with(result_task).once
	    planning_task.thread.join
	    process_events
	end

	plan_task = plan.missions.find { true }
        assert_equal(result_task, plan_task)
	assert_equal(result_task, planning_task.planned_task)
    end

    def test_planning_interruption
        Thread.abort_on_exception = false
        started, normal_finish = nil
        planner = Class.new(Planning::Planner) do
            method(:interruptible) do
                started = true
                10.times do
                    sleep 0.1
                    interruption_point
                end
                normal_finish = true
            end
        end

	planning_task = PlanningTask.new(:planner_model => planner, :method_name => :interruptible)
	plan.permanent(planning_task)
        planning_task.start!
        loop { sleep 0.1 ; break if started }
        planning_task.stop!
        loop do
            begin
                process_events
            rescue Interrupt
            end
            break unless planning_task.running?
        end
        assert(!normal_finish)
    end

    def test_replan_task
	planner = Class.new(Planning::Planner) do
	    method(:test_task) do
	       	result_task = SimpleTask.new(:id => arguments[:task_id])
		result_task.realized_by replan_task(:task_id => arguments[:task_id] + 1)
		plan.permanent(result_task)
		result_task
	    end
	end.new(plan)

	plan.permanent(task = planner.test_task(:task_id => 100))
	assert_kind_of(SimpleTask, task)
	assert_equal(100, task.arguments[:id])

	assert(planning_task = task.enum_child_objects(Roby::TaskStructure::Hierarchy).to_a.first)
	assert_kind_of(PlanningTask, planning_task)
	assert(planning_task.pending?)

	new_task = planning_task_result(planning_task)
	assert_kind_of(SimpleTask, new_task, planning_task)
	assert_equal(101, new_task.arguments[:id])
    end
end
