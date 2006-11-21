require 'test_config'
require 'flexmock'
require 'roby/task'
require 'roby/propagation'
require 'roby/control'
require 'mockups/tasks'

class TC_Exceptions < Test::Unit::TestCase 
    include Roby
    include CommonTestBehaviour

    def test_execution_exception_initialize
	task = Task.new
	error = ExecutionException.new(TaskModelViolation.new(task))
	assert_equal(task, error.task)
	assert_equal([task], error.trace)
	assert_equal(nil, error.generator)
    end

    def test_execution_exception_fork
	task = Task.new
	e = ExecutionException.new(TaskModelViolation.new(task))
	s = e.fork

	assert_equal([e, s], e.siblings)
	assert_equal([e, s], s.siblings)
	e.trace << (t1 = Task.new)
	s.trace << (t2 = Task.new)
	assert_equal([task, t1], e.trace)
	assert_equal([task, t2], s.trace)

	e.merge(s)
	assert_equal([task, [t1, t2]], e.trace)

	s = e.fork
	e.merge(s)
	assert_equal([t1, t2], e.task)
	assert_equal(task, e.origin)

	s = e.fork
	s.trace << (t3 = Task.new)
	e.merge(s)
	assert_equal([t1, t2, t3], e.task)
	assert_equal(task, e.origin)

	e = ExecutionException.new(TaskModelViolation.new(task))
	s = e.fork
	s.trace << (t1 = Task.new) << (t2 = Task.new)
	e.merge(s)
	assert_equal([task, t2], e.task)
	assert_equal(task, e.origin)

	e = ExecutionException.new(TaskModelViolation.new(task))
	s = e.fork
	e.merge(s)
	assert_equal(task, e.task)
	assert_equal(task, e.origin)
    end

    def test_task_handle_exception
	FlexMock.use do |mock|
	    received_handler2 = false
	    klass = Class.new(Task) do 
		on_exception(TaskModelViolation) do |exception|
		    mock.handler1(exception, exception.task, self)
		end
		on_exception(TaskModelViolation) do |exception|
		    if received_handler2
			pass_exception
		    end
		    received_handler2 = true
		    mock.handler2(exception, exception.task, self)
		end
		on_exception(RuntimeError) do |exception|
		    pass_exception
		end
	    end

	    task  = klass.new
	    error = ExecutionException.new(TaskModelViolation.new(task))
	    mock.should_receive(:handler2).with(error, task, task).once.ordered
	    mock.should_receive(:handler1).with(error, task, task).once.ordered
	    assert(task.handle_exception(error))
	    assert(task.handle_exception(error))

	    error = ExecutionException.new(RuntimeError.new, task)
	    assert(! task.handle_exception(error))
	end
    end

    def test_exception_in_handler
	Roby.logger.level = Logger::FATAL

	Control.instance.abort_on_exception = false
	FlexMock.use do |mock|
	    klass = Class.new(ExecutableTask) do
		define_method(:mock) { mock }
		def start(context)
		    mock.event_called
		    raise TaskModelViolation.new(self)
		end
		event :start

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

	    mock.should_receive(:event_called).once.ordered
	    mock.should_receive(:task_handler_called).once.ordered
	    mock.should_receive(:global_handler_called).once.ordered
	    Control.once { t2.start! }
	    assert_nothing_raised { Control.instance.process_events }
	end

    ensure
	Roby.logger.level = Logger::DEBUG
    end

    def test_linear_propagation
	FlexMock.use do |mock|
	    t1, t2 = Task.new, Task.new
	    t0 = Class.new(Task) do 
		on_exception(TaskModelViolation) do |exception|
		    mock.handler(exception, exception.task, self)
		end
	    end.new
	    t0.realized_by t1
	    t1.realized_by t2

	    error = ExecutionException.new(TaskModelViolation.new(t2))
	    mock.should_receive(:handler).with(error, t1, t0).once
	    assert_equal([], Propagation.propagate_exceptions([error]))
	    assert_equal([error], error.siblings)
	    assert_equal([t2, t1], error.trace)

	    error = ExecutionException.new(RuntimeError.new, t2)
	    assert_equal([error], Propagation.propagate_exceptions([error]))
	    assert_equal(t0, error.task)
	    assert_equal([t2, t1, t0], error.trace)

	    # Redo that but this time define a global exception handler
	    error = ExecutionException.new(RuntimeError.new, t2)
	    Roby.on_exception(RuntimeError) do |mod, exception|
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
	    t1, t2, t3 = Task.new, Task.new, Task.new
	    t0 = Class.new(Task) do 
		attr_accessor :handled_exception
		on_exception(TaskModelViolation) do |exception|
		    self.handled_exception = exception
		    mock.handler(exception, exception.task, self)
		end
	    end.new
	    t0.realized_by t1
	    t1.realized_by t2
	    t3.realized_by t2

	    error = ExecutionException.new(TaskModelViolation.new(t2))
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

	    error = ExecutionException.new(RuntimeError.new, t2)
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
	    t1, t2, t3 = Task.new, Task.new, Task.new

	    found_exception = nil
	    t0 = Class.new(Task) do 
		on_exception(TaskModelViolation) do |exception|
		    found_exception = exception
		    mock.handler(exception, exception.task.to_set, self)
		end
	    end.new
	    t0.realized_by t1 ; t1.realized_by t2
	    t0.realized_by t3 ; t3.realized_by t2
	    

	    error = ExecutionException.new(TaskModelViolation.new(t2))
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
	assert_raises(RuntimeError) { ev.call(nil) }
	assert(!ev.happened?)

	# Check that the event is emitted anyway
	ev = EventGenerator.new do |context|
	    ev.emit(context)
	    raise RuntimeError
	end
	assert_raises(RuntimeError) { ev.call(nil) }
	assert(ev.happened?)

	# Check signalling
	ev = EventGenerator.new do |context|
	    ev.emit(context)
	    raise RuntimeError
	end
	ev2 = EventGenerator.new(true)
	ev.on ev2

	assert_raises(RuntimeError) { ev.call(nil) }
	assert(ev.happened?)
	assert(ev2.happened?)

	# Check event handlers
	FlexMock.use do |mock|
	    ev = EventGenerator.new(true)
	    ev.on { mock.handler ; raise RuntimeError }
	    ev.on { mock.handler ; raise RuntimeError }
	    mock.should_receive(:handler).twice
	    assert_raises(RuntimeError) { ev.call }
	end
    end

    # Tests exception handling mechanism during event propagation
    def test_task_propagation_with_exception
	task = Class.new(ExecutableTask) do
	    def start(context)
		emit(:start)
		raise RuntimeError, "failed"
	    end
	    event :start
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

	    Roby::Control.once { task.start! }

	    mock.should_receive(:other_once_handler).once
	    mock.should_receive(:other_event_processing).once
	    Roby::Control.once { mock.other_once_handler }
	    Roby::Control.event_processing << lambda { mock.other_event_processing }

	    assert_raises(RuntimeError) { Roby::Control.instance.process_events }
	end
	assert(task.event(:start).happened?)
    end
end

