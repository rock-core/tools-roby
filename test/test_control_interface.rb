require 'test_config'
require 'flexmock'
require 'mockups/tasks'

require 'roby/control_interface'

class TC_Control < Test::Unit::TestCase 
    include RobyTestCommon

    def teardown
	Control.instance.plan.clear 
	super
    end
    def plan
	Control.instance.plan
    end
    
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

        planning = iface.null_task
        assert(PlanningTask === planning)

        mock_task = control.plan.missions.find { true }
        assert(Task === mock_task, mock_task.class.inspect)

	planning.start!
        poll(0.5) do
            thread_finished = !planning.thread.alive?
            control.process_events
            assert(planning.running? ^ thread_finished)
            break unless planning.running?
        end

	plan_task = control.plan.missions.find { true }
        assert(plan_task == result_task, plan_task)
    end

    class SpecificError < Exception; end
    def test_in_controlthread
	control = Control.instance
	iface   = ControlInterface.new(control)

	control_thread = Thread.current
	t = Thread.new do
	    retval = iface.in_controlthread { Thread.current }
	    assert_equal(control_thread, retval)
	end
	while t.alive?
	    Control.instance.process_events
	    sleep(0.1)
	end

	t = Thread.new do
	    assert_raises(SpecificError) { iface.in_controlthread { raise SpecificError } }
	end
	while t.alive?
	    Control.instance.process_events
	    sleep(0.1)
	end
    end

    URI="druby://localhost:9000"
    def test_remote_interface
        # Start the event loop within a subprocess
        reader, writer = IO.pipe
        server_process = fork do
            Roby::Control.instance.run(:drb => URI) do
                writer.write "OK"
	    end
        end
        reader.read 2

        DRb.start_service
        client = Roby::Client.new("druby://localhost:9000")
        client.quit

        assert_doesnt_timeout(10) do
	    begin
		Process.waitpid(server_process) 
	    rescue Errno::ECHILD
	    end
	end

    ensure
        DRb.stop_service
    end
end

