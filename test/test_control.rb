require 'test_config'
require 'mockups/tasks'

require 'roby/control'
require 'roby/control_interface'
require 'roby/planning'

class TC_Control < Test::Unit::TestCase 
    include Roby

    def teardown
	Control.instance.plan.clear 
	clear_plan_objects
    end
    def plan
	Control.instance.plan
    end

    def test_event_loop
        start_node = EmptyTask.new
        next_event = [ start_node, :start ]
        if_node    = ChoiceTask.new
        start_node.on(:stop) { next_event = [if_node, :start] }
	if_node.on(:stop) {  }
            
        Control.event_processing << lambda do 
            next unless next_event
            task, event = *next_event
            next_event = nil
            task.event(event).call(nil)
        end
        Control.instance.process_events
        assert(start_node.finished?)
	
        Control.instance.process_events
	assert(if_node.finished?)
    end

    include Roby::Planning
    def test_control_interface
        control = Control.instance
        iface   = ControlInterface.new(control)

        task_model = Class.new(Task)

        result_task = nil
        planner = Class.new(Planner) do
            method(:null_task) { result_task = task_model.new }
        end
        control.planners << planner

        planning = iface.null_task
        assert(PlanningTask === planning)
        assert(planning.running?)
        mock_task = control.plan.missions.find { true }
        assert(Task === mock_task, mock_task.class.inspect)

        poll(0.5) do
            thread_finished = !planning.thread.alive?
            control.process_events
            assert(planning.running? ^ thread_finished)
            break unless planning.running?
        end

	plan_task = control.plan.missions.find { true }
        assert(plan_task == result_task, plan_task)
    end
end


