require 'test_config'
require 'flexmock'
require 'roby/task'
require 'roby/propagation'

class TC_Exceptions < Test::Unit::TestCase 
    include Roby

    def test_execution_exception_initialize
	task = Task.new
	error = ExecutionException.new(TaskModelViolation.new(task))
	assert_equal(task, error.task)
	assert_equal([task], error.stack)
	assert_equal(nil, error.generator)
    end

    def test_execution_exception_fork
	task = Task.new
	error = ExecutionException.new(TaskModelViolation.new(task))
	s = error.fork

	assert_equal([error, s], error.siblings)
	assert_equal([error, s], s.siblings)
	s.stack << (t2 = Task.new)
	assert_equal([task], error.stack)
	assert_equal([task, t2], s.stack)

	error.merge(s)
	assert_equal([task, t2], error.task)
    end

    def test_task_handle_exception
	FlexMock.use do |mock|
	    received_handler2 = false
	    klass = Class.new(Task) do 
		on_exception(TaskModelViolation) do |task, exception|
		    mock.handler1(exception, exception.task, task)
		end
		on_exception(TaskModelViolation) do |task, exception|
		    if received_handler2
			task.pass_exception
		    end
		    received_handler2 = true
		    mock.handler2(exception, exception.task, task)
		end
		on_exception(RuntimeError) do |task, exception|
		    task.pass_exception
		end
	    end

	    task  = klass.new
	    error = ExecutionException.new(TaskModelViolation.new(task))
	    mock.should_receive(:handler2).with(error, task, task).ordered
	    mock.should_receive(:handler1).with(error, task, task).ordered

	    error = ExecutionException.new(RuntimeError.new)
	    assert(! task.handle_exception(error))
	end
    end

    def test_linear_propagation
	FlexMock.use do |mock|
	    t1, t2 = Task.new, Task.new
	    t0 = Class.new(Task) do 
		on_exception(TaskModelViolation) do |task, exception|
		    mock.handler(exception, exception.task, task)
		end
	    end.new
	    t0.realized_by t1
	    t1.realized_by t2

	    error = ExecutionException.new(TaskModelViolation.new(t2))
	    mock.should_receive(:handler).with(error, t1, t0)
	    assert_equal([], Propagation.propagate_exceptions([error]))
	    assert_equal([error], error.siblings)
	    assert_equal([t2, t1], error.stack)

	    error = ExecutionException.new(RuntimeError.new, t2)
	    assert_equal([error], Propagation.propagate_exceptions([error]))
	end
    end

    def test_forked_propagation
	# We build a 0 -> 1 -> 2 3 -> 2 task tree with
	# 0 being able to handle the exception and 1, 3 not

	FlexMock.use do |mock|
	    t1, t2, t3 = Task.new, Task.new, Task.new
	    t0 = Class.new(Task) do 
		on_exception(TaskModelViolation) do |task, exception|
		    mock.handler(exception, exception.task, task)
		end
	    end.new
	    t0.realized_by t1
	    t1.realized_by t2
	    t3.realized_by t2

	    error = ExecutionException.new(TaskModelViolation.new(t2))
	    mock.should_receive(:handler).with(error, t1, t0)
	    assert_equal([], Propagation.propagate_exceptions([error]))
	    assert_equal([t2, t1], error.stack)

	    error = ExecutionException.new(RuntimeError.new, t2)
	    assert(fatal = Propagation.propagate_exceptions([error]))
	    assert_equal(2, fatal.size)
	    e1 = fatal.find { |e| e == error }
	    e2 = fatal.find { |e| e != error }
	    assert_equal([e1, e2], e2.siblings)
	    assert_equal([t2, t3], e2.stack)
	end
    end

    def test_diamond_propagation
	# We build a 0 -> 1 -> 2 3 -> 2 task tree with
	# 0 being able to handle the exception and 1, 3 not

	FlexMock.use do |mock|
	    t1, t2, t3 = Task.new, Task.new, Task.new

	    found_exception = nil
	    t0 = Class.new(Task) do 
		on_exception(TaskModelViolation) do |task, exception|
		    found_exception = exception
		    mock.handler(exception, exception.task.to_set, task)
		end
	    end.new
	    t0.realized_by t1
	    t1.realized_by t2
	    t3.realized_by t2
	    t0.realized_by t3

	    error = ExecutionException.new(TaskModelViolation.new(t2))
	    mock.should_receive(:handler).with(ExecutionException, [t1, t3].to_set, t0).once
	    assert_equal([], Propagation.propagate_exceptions([error]))
	    assert_equal([t2, [t3, t1]].to_set, found_exception.stack.to_set)
	end
    end
end

