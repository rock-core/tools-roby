require 'test_config'
require 'roby/control'
require 'roby/plan'
require 'mockups/tasks'

class TC_Control < Test::Unit::TestCase 
    include Roby

    def setup; Control.instance.clear end
    def teardown; Control.instance.clear end

    def test_event_loop
        start_node = EmptyTask.new
        next_event = [ start_node, :start ]
        if_node    = ChoiceTask.new
        start_node.on(:stop) { next_event = [if_node, :start] }
	if_node.on(:stop) { raise Interrupt }
            
        Control.event_processing << lambda do 
            next unless next_event
            task, event = *next_event
            next_event = nil
            task.event(event).call(nil)
        end
        assert_doesnt_timeout(1) { Control.instance.run }
        assert(start_node.finished?)
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
        end.new(control)
        control.planners << planner

        planning = iface.null_task
        assert(PlanningTask === planning)
        assert(planning.running?)
        mock_task = control.missions.find { true }
        assert(Task === mock_task, mock_task.class.inspect)

        poll(0.5) do
            thread_finished = !planning.thread.alive?
            control.process_events
            assert(planning.running? ^ thread_finished)
            break unless planning.running?
        end

	plan_task = control.missions.find { true }
        assert(plan_task == result_task, plan_task)
    end
end


