$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/test/tasks/simple_task'

require 'roby'

class TC_Exceptions < Test::Unit::TestCase 
    include Roby::Test
    class SpecializedError < LocalizedError; end

    def test_execution_exception_initialize
	plan.discover(task = Task.new)
	error = ExecutionException.new(LocalizedError.new(task))
	assert_equal(task, error.task)
	assert_equal([task], error.trace)
	assert_equal(nil, error.generator)

	ev = task.event(:start)
	error = ExecutionException.new(LocalizedError.new(ev))
	assert_equal(task, error.task)
	assert_equal(ev, error.generator)
	assert_equal([task], error.trace)
    end

    def test_execution_exception_fork
	task, t1, t2, t3 = prepare_plan :discover => 5
	e = ExecutionException.new(LocalizedError.new(task))
	s = e.fork

	assert_equal([e, s], e.siblings)
	assert_equal([e, s], s.siblings)
	e.trace << t1
	s.trace << t2
	assert_equal([task, t1], e.trace)
	assert_equal([task, t2], s.trace)

	e.merge(s)
	assert_equal([task, [t1, t2]], e.trace)

	s = e.fork
	e.merge(s)
	assert_equal([t1, t2], e.task)
	assert_equal(task, e.origin)

	s = e.fork
	s.trace << t3
	e.merge(s)
	assert_equal([t1, t2, t3], e.task)
	assert_equal(task, e.origin)

	e = ExecutionException.new(LocalizedError.new(task))
	s = e.fork
	t1, t2 = prepare_plan :discover => 2
	s.trace << t1 << t2
	e.merge(s)
	assert_equal([task, t2], e.task)
	assert_equal(task, e.origin)

	e = ExecutionException.new(LocalizedError.new(task))
	s = e.fork
	e.merge(s)
	assert_equal(task, e.task)
	assert_equal(task, e.origin)
    end

    class SignallingHandler < Roby::LocalizedError; end
    def test_task_handle_exception
	FlexMock.use do |mock|
	    received_handler2 = false
	    klass = Class.new(Task) do 
		on_exception(SpecializedError) do |exception|
		    mock.handler1(exception, exception.task, self)
		end
		on_exception(SpecializedError) do |exception|
		    if received_handler2
			pass_exception
		    end
		    received_handler2 = true
		    mock.handler2(exception, exception.task, self)
		end
		on_exception(RuntimeError) do |exception|
		    pass_exception
		end
		on_exception(SignalException) do |exception|
		    raise
		end
	    end

	    plan.discover(task  = klass.new)
	    error = ExecutionException.new(SpecializedError.new(task))
	    mock.should_receive(:handler2).with(error, task, task).once.ordered
	    mock.should_receive(:handler1).with(error, task, task).once.ordered
	    assert(task.handle_exception(error))
	    assert(task.handle_exception(error))

	    error = ExecutionException.new(CodeError.new(nil, task))
	    assert(! task.handle_exception(error))
	    error = ExecutionException.new(SignallingHandler.new(task))
	    assert(! task.handle_exception(error))
	end
    end

    def test_exception_in_handler
	Roby.logger.level = Logger::FATAL

	Roby.control.abort_on_exception = true
	Roby.control.abort_on_application_exception = false
	FlexMock.use do |mock|
	    klass = Class.new(SimpleTask) do
		define_method(:mock) { mock }
		event :start do |context|
		    mock.event_called
		    raise SpecializedError.new(self)
                end

		on_exception(RuntimeError) do |exception|
		    mock.task_handler_called
		    raise 
		end
	    end

	    Roby.on_exception(RuntimeError) do |task, exception|
		mock.global_handler_called
		raise
	    end

	    t1, t2 = klass.new, klass.new
	    t1.realized_by t2
	    plan.insert(t1)

	    mock.should_receive(:event_called).once.ordered
	    mock.should_receive(:task_handler_called).once.ordered
	    mock.should_receive(:global_handler_called).once.ordered
	    Control.once { t2.start! }
	    assert_raises(SpecializedError) { process_events }
	end
    end

    def test_linear_propagation
	FlexMock.use do |mock|
	    t1, t2 = Task.new, Task.new
	    t0 = Class.new(Task) do 
		on_exception(SpecializedError) do |exception|
		    mock.handler(exception, exception.task, self)
		end
	    end.new
	    plan.discover(t0)
	    t0.realized_by t1
	    t1.realized_by t2

	    error = ExecutionException.new(SpecializedError.new(t2))
	    mock.should_receive(:handler).with(error, t1, t0).once
	    assert_equal([], Propagation.propagate_exceptions([error]))
	    assert_equal([error], error.siblings)
	    assert_equal([t2, t1], error.trace)

	    error = ExecutionException.new(CodeError.new(nil, t2))
	    assert_equal([error], Propagation.propagate_exceptions([error]))
	    assert_equal(t0, error.task)
	    assert_equal([t2, t1, t0], error.trace)

	    # Redo that but this time define a global exception handler
	    error = ExecutionException.new(CodeError.new(nil, t2))
	    Roby.on_exception(CodeError) do |mod, exception|
		mock.global_handler(exception, exception.task, mod)
	    end
	    mock.should_receive(:global_handler).with(error, t0, Roby).once
	    assert_equal([], Propagation.propagate_exceptions([error]))
	end
    end

    def test_forked_propagation
	# We build a 0 -> 1 -> 2 3 -> 2 task tree with
	# 0 being able to handle the exception and 1, 3 not

	FlexMock.use do |mock|
	    t1, t2, t3 = prepare_plan :discover => 3
	    t0 = Class.new(Task) do 
		attr_accessor :handled_exception
		on_exception(CodeError) do |exception|
		    self.handled_exception = exception
		    mock.handler(exception, exception.task, self)
		end
	    end.new
	    plan.discover(t0)
	    t0.realized_by t1
	    t1.realized_by t2
	    t3.realized_by t2

	    error = ExecutionException.new(CodeError.new(nil, t2))
	    mock.should_receive(:handler).with(ExecutionException, t1, t0).once
	    # There are two possibilities here:
	    #	1/ the error propagation begins with t1 -> t0, in which case +error+
	    #	   is t0.handled_exception and there may be no sibling (the error is
	    #	   never tested on t3
	    #	2/ propagation begins with t3, in which case +error+ is a sibling of
	    #	   t0.handled_exception
	    assert_equal([], Propagation.propagate_exceptions([error]))
	    assert_equal([t2, t1], t0.handled_exception.trace)
	    if t0.handled_exception != error
		assert_equal([t2, t3], error.trace)
		assert_equal([t0.handled_exception, error].to_set, error.siblings.to_set)
	    end

	    error = ExecutionException.new(LocalizedError.new(t2))
	    assert(fatal = Propagation.propagate_exceptions([error]))
	    assert_equal(1, fatal.size)
	    e = *fatal
	    assert_equal(t2, e.origin)
	    assert_equal([t3, t0], e.task)
	end
    end

    def test_diamond_propagation
	# We build a 0 -> 1 -> 2 3 -> 2 task tree with
	# 0 being able to handle the exception and 1, 3 not

	FlexMock.use do |mock|
	    t1, t2, t3 = prepare_plan :discover => 3

	    found_exception = nil
	    t0 = Class.new(Task) do 
		on_exception(LocalizedError) do |exception|
		    found_exception = exception
		    mock.handler(exception, exception.task.to_set, self)
		end
	    end.new
	    plan.discover(t0)
	    t0.realized_by t1 ; t1.realized_by t2
	    t0.realized_by t3 ; t3.realized_by t2
	    

	    error = ExecutionException.new(LocalizedError.new(t2))
	    mock.should_receive(:handler).with(ExecutionException, [t1, t3].to_set, t0).once
	    assert_equal([], Propagation.propagate_exceptions([error]))
	    assert_equal(2, found_exception.trace.size, found_exception.trace)
	    assert_equal(t2, found_exception.origin)
	    assert_equal([t3, t1].to_set, found_exception.task.to_set)
	end
    end

    def test_event_propagation_with_exception
	ev = EventGenerator.new do |context|
	    raise RuntimeError
	    ev.emit(context)
	end
	plan.discover(ev)
	assert_original_error(RuntimeError, CommandFailed) { ev.call(nil) }
	assert(!ev.happened?)

	# Check that the event is emitted anyway
	ev = EventGenerator.new do |context|
	    ev.emit(context)
	    raise RuntimeError
	end
	plan.discover(ev)
	assert_original_error(RuntimeError, CommandFailed) { ev.call(nil) }
	assert(ev.happened?)

	# Check signalling
	ev = EventGenerator.new do |context|
	    ev.emit(context)
	    raise RuntimeError
	end
	plan.discover(ev)
	ev2 = EventGenerator.new(true)
	ev.on ev2

	assert_original_error(RuntimeError, CommandFailed) { ev.call(nil) }
	assert(ev.happened?)
	assert(ev2.happened?)

	# Check event handlers
	FlexMock.use do |mock|
	    ev = EventGenerator.new(true)
	    plan.discover(ev)
	    ev.on { mock.handler ; raise RuntimeError }
	    ev.on { mock.handler }
	    mock.should_receive(:handler).twice
	    assert_original_error(RuntimeError, EventHandlerError) { ev.call }
	end
    end

    # Tests exception handling mechanism during event propagation
    def test_task_propagation_with_exception
	Roby.control.abort_on_exception = true
	Roby.logger.level = Logger::FATAL

	task = Class.new(SimpleTask) do
	    event :start do |context|
		emit(:start)
		raise RuntimeError, "failed"
            end
	end.new

	FlexMock.use do |mock|
	    parent = Class.new(Task) do
		on_exception RuntimeError do
		    mock.exception
		    task.pass_exception
		end
	    end.new
	    mock.should_receive(:exception).once

	    parent.realized_by task
	    plan.insert(parent)

	    Roby::Control.once { task.start! }

	    mock.should_receive(:other_once_handler).once
	    mock.should_receive(:other_event_processing).once
	    Roby::Control.once { mock.other_once_handler }
	    Roby::Control.event_processing << lambda { mock.other_event_processing }

	    begin
		process_events
		flunk("should have raised")
	    rescue Roby::CommandFailed => e
		assert_kind_of(RuntimeError, e.error)
	    end
	end
	assert(task.event(:start).happened?)
    end

    def test_exception_argument_count_validation
        assert_raises(ArgumentError) do
            Class.new(Task).on_exception(RuntimeError) do ||
            end
        end
        assert_raises(ArgumentError) do
            Class.new(Task).on_exception(RuntimeError) do |a, b|
            end
        end
        assert_nothing_raised do
            Class.new(Task).on_exception(RuntimeError) do |_|
            end
        end

        assert_raises(ArgumentError) do
            Roby.on_exception(RuntimeError) do ||
            end
        end
        assert_raises(ArgumentError) do |a, b|
            Roby.on_exception(RuntimeError) do |_|
            end
        end
        assert_nothing_raised do
            Roby.on_exception(RuntimeError) do |_, _|
            end
        end
    end

    def test_exception_propagation_merging
	FlexMock.use do |mock|
	    t11 = Task.new(:id => '11')
	    t12 = Task.new(:id => '12')
	    t13 = Task.new(:id => '13')

	    root = Class.new(Task) do
		include Test::Unit::Assertions
		on_exception(RuntimeError) do |exception|
		    assert_equal([t11, t12, t13].to_set, exception.task.to_set)
		    mock.caught(exception.task)
		end
	    end.new(:id => 'root')
	    plan.discover(root)
	    root.realized_by(t11)
	    root.realized_by(t12)
	    root.realized_by(t13)

	    t11.realized_by(t21 = Task.new(:id => '21'))
	    t12.realized_by(t21)

	    t13.realized_by(t22 = Task.new(:id => '22'))
	    t22.realized_by(t31 = Task.new(:id => '31'))
	    t31.realized_by(t21)

	    mock.should_receive(:caught).once
	    Propagation.propagate_exceptions([ExecutionException.new(LocalizedError.new(t21))])
	end
    end

    def test_plan_repairs
	model = Class.new(SimpleTask) do
	    event :blocked
	    forward :blocked => :failed
	end

	# First, check methods located in Plan
	plan.discover(task = model.new)
	r1, r2 = SimpleTask.new, SimpleTask.new

	task.start!
	task.emit :blocked

	blocked_event = task.history[-3]
	failed_event  = task.history[-2]
	stop_event    = task.history[-1]
	plan.add_repair failed_event, r1
	plan.add_repair blocked_event, r2
	assert(plan.task_index.repaired_tasks.include?(task))

	assert_equal({}, plan.repairs_for(stop_event))
	assert_equal({failed_event => r1}, plan.repairs_for(failed_event))
	assert_equal({blocked_event => r2, failed_event => r1}, plan.repairs_for(blocked_event))
	plan.remove_repair r1
	assert_equal({}, plan.repairs_for(failed_event))
	assert_equal({blocked_event => r2}, plan.repairs_for(blocked_event))
	plan.remove_repair r2
	assert_equal({}, plan.repairs_for(stop_event))
	assert_equal({}, plan.repairs_for(failed_event))
	assert_equal({}, plan.repairs_for(blocked_event))
	assert(!plan.task_index.repaired_tasks.include?(task))
    end

    def test_exception_inhibition
	parent, child = prepare_plan :tasks => 2, :model => SimpleTask
	plan.insert(parent)
	parent.realized_by child
	parent.on :start, child, :start
	parent.start!
	child.failed!

	exceptions = Roby.control.structure_checking

	plan.discover(repairing_task = SimpleTask.new)
	repairing_task.start!
	assert_equal(exceptions.to_a, Propagation.remove_inhibited_exceptions(exceptions))
	assert_equal(exceptions.keys, Propagation.propagate_exceptions(exceptions))
	plan.add_repair(child.terminal_event, repairing_task)
	assert_equal([], Propagation.remove_inhibited_exceptions(exceptions))
	assert_equal([], Propagation.propagate_exceptions(exceptions))

    ensure
	# Remove the child so that the test's plan cleanup does not complain
	parent.remove_child child if child
    end

    def test_error_handling_relation(error_event = :failed)
	task_model = Class.new(SimpleTask) do
	    event :blocked
	    forward :blocked => :failed
	end

	parent, child = prepare_plan :tasks => 2, :model => task_model
	plan.insert(parent)
	parent.realized_by child
	repairing_task = SimpleTask.new
	child.event(:failed).handle_with repairing_task

	parent.start!
	child.start!
	child.emit error_event

	exceptions = Roby.control.structure_checking

	assert_equal([], Propagation.propagate_exceptions(exceptions))
	assert_equal({ child.terminal_event => repairing_task },
		     plan.repairs_for(child.terminal_event), [plan.repairs, child.terminal_event])

	Roby.control.abort_on_exception = false
	process_events
	assert(repairing_task.running?)

	# Make the "repair task" finish, but do not repair the plan.
	# propagate_exceptions must not add a new repair
	repairing_task.success!
	assert_equal(exceptions.keys, Propagation.propagate_exceptions(exceptions))

    ensure
	parent.remove_child child if child
    end

    def test_error_handling_relation_generalization
	test_error_handling_relation(:blocked)
    end

    def test_handling_missions_exceptions
	mission = prepare_plan :missions => 1, :model => SimpleTask
	repairing_task = SimpleTask.new
	mission.event(:failed).handle_with repairing_task

	mission.start!
	mission.emit :failed

	exceptions = Roby.control.structure_checking
	assert_equal(1, exceptions.size)
	assert_kind_of(Roby::MissionFailedError, exceptions.to_a[0][0].exception, exceptions)

	assert_equal([], Propagation.propagate_exceptions(exceptions))
	assert_equal({ mission.terminal_event => repairing_task },
		     plan.repairs_for(mission.terminal_event), [plan.repairs, mission.terminal_event])

	Roby.control.abort_on_exception = false
	process_events
	assert(plan.mission?(mission))
	assert(repairing_task.running?)

	# Make the "repair task" finish, but do not repair the plan.
	# propagate_exceptions must not add a new repair
	repairing_task.success!
	assert_equal(exceptions.keys, Propagation.propagate_exceptions(exceptions))

	# Discard the mission so that the test teardown does not complain
	plan.discard(mission)
    end

    def test_filter_command_errors
        model = Class.new(SimpleTask) do
            event :start do
                raise ArgumentError
            end
        end

        task = prepare_plan :permanent => 1, :model => model
        error = begin task.start!
                rescue Exception => e; e
                end
        assert_kind_of CodeError, e
        assert_nothing_raised do
            Roby.format_exception e
        end

        trace = e.error.backtrace
        filtered = Roby.filter_backtrace(trace)
        assert(filtered[0] =~ /command for 'start'/, filtered[0])
        assert(filtered[1] =~ /test_filter_command_errors/,   filtered[1])
    end

    def test_filter_handler_errors
        task = prepare_plan :permanent => 1, :model => SimpleTask
        task.on(:start) { raise ArgumentError }
        error = begin task.start!
                rescue Exception => e; e
                end
        assert_kind_of CodeError, e
        assert_nothing_raised do
            Roby.format_exception e
        end
    end

    def test_filter_polling_errors
        #Roby.control.fatal_exceptions = false

        model = Class.new(SimpleTask) do
            poll do
                raise ArgumentError, "bla"
            end
        end

        parent = prepare_plan :permanent => 1, :model => SimpleTask
        child = prepare_plan :permanent => 1, :model => model
        parent.realized_by child
        parent.start!
        child.start!
        child.failed!

	error = TaskStructure::Hierarchy.check_structure(plan).first.exception
	assert_kind_of(ChildFailedError, error)
        assert_nothing_raised do
            Roby.format_exception(error)
        end
        # To silently finish the test ...
        parent.stop!
    end
end

