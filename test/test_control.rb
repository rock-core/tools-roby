$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'mockups/tasks'

class TC_Control < Test::Unit::TestCase 
    include Roby::Test

    def test_application_error
	# Shut up the logger in this test
	Roby.logger.level = Logger::FATAL
	exception = begin; raise RuntimeError
		    rescue; $!
		    end

	Roby.control.abort_on_application_exception = false
	assert_nothing_raised { Roby.application_error(:exceptions, Task, exception) }

	Roby.control.abort_on_application_exception = true
	assert_raises(RuntimeError) { Roby.application_error(:exceptions, Task, exception) }
    end

    def test_event_loop
        plan.insert(start_node = EmptyTask.new)
        next_event = [ start_node, :start ]
        plan.insert(if_node    = ChoiceTask.new)
        start_node.on(:stop) { next_event = [if_node, :start] }
	if_node.on(:stop) {  }
            
        Control.event_processing << lambda do 
            next unless next_event
            task, event = *next_event
            next_event = nil
            task.event(event).call(nil)
        end
        process_events
        assert(start_node.finished?)
	
        process_events
	assert(if_node.finished?)
    end

    def test_once
	FlexMock.use do |mock|
	    Control.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	end
	FlexMock.use do |mock|
	    Control.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	    process_events
	end
    end


    class SpecificException < RuntimeError; end
    def test_unhandled_event_exceptions
	Roby.control.abort_on_exception = true

	# Test that the event is not pending if the command raises
	model = Class.new(SimpleTask) do
	    def start(context)
		raise SpecificException, "bla"
	    end
	    event :start
	end
	plan.insert(t = model.new)
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
	    plan.insert(t)

	    mock.should_receive(:command_called).once
	    mock.should_receive(:handler_called).never

	    Control.once { t.start!(nil) }
	    assert_raises(Aborting) { process_events }
	    assert(!t.event(:start).pending)
	end

	# Check that the task has been garbage collected in the process
	assert(! plan.include?(t))
    end

    def apply_structure_checking(&block)
	Control.structure_checks.clear
	Control.structure_checks << lambda(&block)
	process_events
    ensure
	Control.structure_checks.clear
    end

    def test_structure_checking
	Roby.control.abort_on_exception = false

	# Check on a single task
	plan.insert(t = SimpleTask.new)
	apply_structure_checking { TaskModelViolation.new(t) }
	assert(! plan.include?(t))

	# Make sure that a task which has been repaired will not be killed
	plan.insert(t = SimpleTask.new)
	did_once = false
	apply_structure_checking do
	    unless did_once
		did_once = true
		TaskModelViolation.new(t)
	    end
	end
	assert(plan.include?(t))

	# Check that whole task trees are killed
	t0, t1, t2, t3 = prepare_plan :discover => 4
	t0.realized_by t2
	t1.realized_by t2
	t2.realized_by t3

	plan.insert(t0)
	plan.insert(t1)
	FlexMock.use do |mock|
	    mock.should_receive(:checking).twice
	    apply_structure_checking do
		mock.checking
		TaskModelViolation.new(t2)
	    end
	end
	assert(!plan.include?(t0))
	assert(!plan.include?(t1))
	assert(!plan.include?(t2))
	process_events
	assert(!plan.include?(t3))

	# Check that we can kill selectively by returning a hash
	t0, t1, t2 = prepare_plan :discover => 3
	t0.realized_by t2
	t1.realized_by t2
	plan.insert(t0)
	plan.insert(t1)
	apply_structure_checking { { TaskModelViolation.new(t2) => t0 } }
	assert(!plan.include?(t0))
	assert(plan.include?(t1))
	assert(plan.include?(t2))
    end

    def test_at_cycle_end
	# Shut up the logger in this test
	Roby.logger.level = Logger::FATAL
        Roby.control.abort_on_application_exception = false

        FlexMock.use do |mock|
            mock.should_receive(:before_error).once
            mock.should_receive(:after_error).never
            mock.should_receive(:called).once
            Control.at_cycle_end do
               	mock.before_error
        	raise
        	mock.after_error
            end
            Control.at_cycle_end do
               	mock.called
		unless Roby.control.quitting?
		    Roby.control.quit
		end
            end
            Roby.control.run
        end
    end
end


