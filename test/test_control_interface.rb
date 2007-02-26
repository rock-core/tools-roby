$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'mockups/tasks'

class TC_Control < Test::Unit::TestCase 
    include Roby::Test

    include Roby::Planning
    def test_method_missing
        control = Control.instance
        iface   = ControlInterface.new(control)

        task_model = Class.new(Task)

        result_task = nil
        planner = Class.new(Planner) do
            method(:null_task) { result_task = task_model.new }
        end
        control.planners << planner

        planning = nil
	iface.null_task do |planning, _|
	end
	process_events
        assert_kind_of(PlanningTask, planning)

        mock_task = plan.missions.find { true }
        assert(Task === mock_task, mock_task.class.inspect)

	planning.start!
        poll(0.5) do
            thread_finished = !planning.thread.alive?
            process_events
            assert(planning.running? ^ thread_finished)
            break unless planning.running?
        end

	plan_task = plan.missions.find { true }
        assert(plan_task == result_task, plan_task)
    end
end

