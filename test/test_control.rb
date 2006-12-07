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


    class SpecificException < RuntimeError; end
    def test_unhandled_event_exceptions
	Control.instance.abort_on_exception = true

	# Test that the event is not pending if the command raises
	t = Class.new(SimpleTask) do
	    def start(context)
		raise SpecificException, "bla"
	    end
	    event :start
	end.new
	begin; t.start!
	rescue SpecificException
	end
	assert(!t.event(:start).pending?)

	# Check that the propagation is pruned if the command raises
	t = nil
	FlexMock.use do |mock|
	    t = Class.new(SimpleTask) do
		define_method(:start) do |context|
		    mock.command_called
		    raise SpecificException, "bla"
		    emit :start
		end
		event :start
		on(:start) { mock.handler_called }
	    end.new

	    mock.should_receive(:command_called).once
	    mock.should_receive(:handler_called).never

	    Control.once { t.start!(nil) }
	    assert_raises(SpecificException) { Control.instance.process_events }
	    assert_equal(0, t.event(:start).pending)
	end

	# Check that the task has been garbage collected in the process
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


