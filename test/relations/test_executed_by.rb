$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/common'
require 'test/mockups/tasks'
require 'flexmock'

class TC_ExecutedBy < Test::Unit::TestCase
    include Roby::Test

    attr_reader :plan
    def setup
	@plan = Plan.new
	super
    end

    def test_relationships
	task = SimpleTask.new
	exec_task = Class.new(ExecutableTask) do
	    event(:start, :command => true)
	    event(:ready)
	    on :start => :ready
	end.new

	task.executed_by exec_task
	assert_equal(exec_task, task.execution_agent)
    end

    def test_nominal
	task = SimpleTask.new
	exec_klass = Class.new(SimpleTask) do
	    event(:ready)
	    on :start => :ready
	end
	exec1, exec2 = exec_klass.new, exec_klass.new
	task.executed_by exec2
	task.executed_by exec1

	FlexMock.use do |mock|
	    exec1.on(:start) { mock.agent_started }
	    exec1.on(:ready) { mock.agent_ready }
	    task.on(:start) { mock.task_started }

	    mock.should_receive(:agent_started).once.ordered
	    mock.should_receive(:agent_ready).once.ordered
	    mock.should_receive(:task_started).once.ordered
	    task.start!
	end

	task.stop!
	assert_nothing_raised { exec1.stop! }
    end

    def test_agent_fails
	task = SimpleTask.new
	exec = Class.new(SimpleTask) do
	    event(:ready)
	    on :start => :ready
	end.new
	task.executed_by exec
	task.start!

	FlexMock.use do |mock|
	    task.on(:aborted) { mock.aborted }
	    mock.should_receive(:aborted).once
	    exec.stop!
	end
	assert(!task.running?)
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
	exec_model = Class.new(SimpleTask) do
	    event(:ready)
	    on :start => :ready
	end

	task_model.executed_by exec_model
	task = task_model.new
	plan.insert(task)
	assert(task.execution_agent)
	assert(exec_model, task.execution_agent.class)

	task.start!
	assert(task.running?)
	assert(task.execution_agent.running?)
    end

    def test_respawn
	task_model = Class.new(SimpleTask)
	exec_model = Class.new(SimpleTask) do
	    event(:ready)
	    on :start => :ready
	end

	task_model.executed_by exec_model
	first, second = prepare_plan :missions => 2, :model => task_model
	assert(first.execution_agent)
	assert(exec_model, first.execution_agent.class)
	assert(second.execution_agent)
	assert(exec_model, second.execution_agent.class)

	first.start!
	assert(first.running?)
	first_agent = first.execution_agent
	assert(first_agent.running?)

	first.execution_agent.stop!
	assert(first.event(:aborted).happened?)
	assert(first_agent.finished?)
	assert(second.execution_agent)
	assert(second.execution_agent.pending?)
    end

    def test_cannot_respawn
	task_model = Class.new(SimpleTask)
	exec_model = Class.new(SimpleTask) do
	    event(:ready)
	    on :start => :ready
	end

	task  = task_model.new
	agent = exec_model.new
	task.executed_by agent

	agent.start!
	agent.stop!
	assert_raises(Roby::TaskModelViolation) { task.start! }
    end
end

