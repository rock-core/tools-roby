require 'test/unit'
require 'test_config'
require 'roby/relations'
require 'roby/relations/executed_by'

require 'roby/task'
require 'flexmock'

class TC_ExecutedBy < Test::Unit::TestCase
    include Roby

    def test_nominal
	task = Class.new(Task) { event(:start, :command => true) }.new
	exec = Class.new(Task) do
	    event(:start, :command => true)
	    event(:ready)
	    on :start => :ready
	end.new
	task.executed_by exec

	task.start!
	assert(exec.running?)
	assert(task.running?)
    end

    def test_agent_start_failed
	task = Class.new(Task) { event(:start, :command => true) }.new
	exec = Class.new(Task) do
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
	task_model = Class.new(Task) { event(:start, :command => true) }
	exec_model = Class.new(Task) do
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

