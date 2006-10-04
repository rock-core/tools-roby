require 'test/unit'
require 'test_config'
require 'roby/relations'
require 'roby/relations/executed_by'

require 'roby/task'
require 'flexmock'

class TC_ExecutedBy < Test::Unit::TestCase
    include Roby

    def teardown
	clear_plan_objects
    end

    def test_nominal
	task = SimpleTask.new
	exec_klass = Class.new(ExecutableTask) do
	    event(:start, :command => true)
	    event(:ready)
	    on :start => :ready
	end
	exec1, exec2 = exec_klass.new, exec_klass.new
	task.executed_by exec2

	task.executed_by exec1

	task.start!
	assert(exec1.running?)
	assert(!exec2.running?)
	assert(task.running?)
    end

    def test_agent_start_failed
	task = SimpleTask.new
	exec = Class.new(ExecutableTask) do
	    event(:start, :command => true)
	    event(:ready)
	    on :start => :failed
	end.new
	task.executed_by exec

	assert_raises(EventModelViolation) { task.start! }
	assert(!task.running?)
	assert(!exec.running?)
	assert(exec.finished?)
    end

    def test_agent_model
	task_model = Class.new(SimpleTask)
	exec_model = Class.new(ExecutableTask) do
	    event(:start, :command => true)
	    event(:ready)
	    on :start => :ready
	end

	task_model.executed_by exec_model
	task = task_model.new

	task.start!
	assert(task.execution_agent)
	assert(exec_model, task.execution_agent.class)

	assert(task.running?)
	assert(task.execution_agent.running?)
    end
end

