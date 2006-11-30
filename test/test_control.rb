require 'test_config'
require 'flexmock'
require 'mockups/tasks'

require 'roby/control'
require 'roby/control_interface'
require 'roby/planning'

class TC_Control < Test::Unit::TestCase 
    include Roby
    include RobyTestCommon

    def teardown
	Control.instance.plan.clear 
	super
    end
    def plan
	Control.instance.plan
    end
    
    def test_application_error
	# Shut up the logger in this test
	Roby.logger.level = Logger::FATAL
	exception = begin; raise RuntimeError
		    rescue; $!
		    end

	Control.instance.abort_on_application_exception = false
	assert_nothing_raised { Roby.application_error(:exceptions, exception, Task) }

	Control.instance.abort_on_application_exception = true
	assert_raises(RuntimeError) { Roby.application_error(:exceptions, exception, Task) }

    ensure
	Roby.logger.level = Logger::DEBUG
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

    def test_once
	FlexMock.use do |mock|
	    Control.once { mock.called }
	    mock.should_receive(:called).once
	    Control.instance.process_events
	end
	FlexMock.use do |mock|
	    Control.once { mock.called }
	    mock.should_receive(:called).once
	    Control.instance.process_events
	    Control.instance.process_events
	end
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

    def test_unhandled_event_exceptions
	Control.instance.abort_on_exception = false
	t = Class.new(Task) do
	    def start(context)
		raise RuntimeError, "bla"
	    end
	    event :start
	end.new

	Control.once { t.start!(nil) }
	Control.instance.process_events
	assert(! plan.include?(t))
    end

    def test_structure_checking
	Control.instance.abort_on_exception = false

	# Check on a single task
	Control.structure_checks.clear
	t = SimpleTask.new
	plan.insert(t)
	Control.structure_checks << lambda { TaskModelViolation.new(t) }

	Control.instance.process_events
	assert(! plan.include?(t))

	# Make sure that a task which has been repaired will not be killed
	Control.structure_checks.clear
	t = SimpleTask.new
	plan.insert(t)
	did_once = false
	Control.structure_checks << lambda { 
	    unless did_once
		did_once = true
		TaskModelViolation.new(t)
	    end
	}
	Control.instance.process_events
	assert(plan.include?(t))

	# Check that the whole task trees are killed
	tasks = (1..4).map { SimpleTask.new }
	t0, t1, t2, t3 = *tasks
	t0.realized_by t2
	t1.realized_by t2
	t2.realized_by t3

	plan.insert(t0)
	plan.insert(t1)
	FlexMock.use do |mock|
	    Control.structure_checks.clear
	    Control.structure_checks << lambda { mock.checking ; TaskModelViolation.new(t2) }
	    mock.should_receive(:checking).twice

	    Control.instance.process_events
	end
	assert(!plan.include?(t0))
	assert(!plan.include?(t1))
	assert(!plan.include?(t2))
	assert(!plan.include?(t3))


	# Check that we can kill selectively by returning a hash
	tasks = (1..3).map { SimpleTask.new }
	t0, t1, t2 = tasks
	t0.realized_by t2
	t1.realized_by t2
	plan.insert(t0)
	plan.insert(t1)
	Control.structure_checks.clear
	Control.structure_checks << lambda { { TaskModelViolation.new(t2) => t0 } }
	Control.instance.process_events
	assert(!plan.include?(t0))
	assert(plan.include?(t1))
	assert(plan.include?(t2))
    end

end


