$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/common'
require 'test/mockups/tasks'
require 'flexmock'

class TC_ExecutedBy < Test::Unit::TestCase
    include Roby::Test

    class ExecutionAgentModel < SimpleTask
	event :ready
	forward :start => :ready
    end

    def test_relationships
	task = SimpleTask.new
	exec_task = ExecutionAgentModel.new

	task.executed_by exec_task
	assert_equal(exec_task, task.execution_agent)
    end

    def test_nominal
	plan.insert(task = SimpleTask.new)
	task.executed_by(ExecutionAgentModel.new)
	task.executed_by(exec = ExecutionAgentModel.new)

	FlexMock.use do |mock|
	    exec.on(:start) { mock.agent_started }
	    exec.on(:ready) { mock.agent_ready }
	    task.on(:start) { mock.task_started }

	    mock.should_receive(:agent_started).once.ordered
	    mock.should_receive(:agent_ready).once.ordered
	    mock.should_receive(:task_started).once.ordered
	    task.start!
	end

	task.stop!
	assert_nothing_raised { exec.stop! }
    end

    def test_agent_fails
	plan.insert(task = SimpleTask.new)
	exec = ExecutionAgentModel.new
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
	plan.insert(task = SimpleTask.new)
	exec = Class.new(SimpleTask) do
	    event :ready
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

	task_model.executed_by ExecutionAgentModel
	plan.insert(task = task_model.new)
	assert(task.execution_agent)
	assert(ExecutionAgentModel, task.execution_agent.class)

	task.start!
	assert(task.running?)
	assert(task.execution_agent.running?)
    end

    def test_respawn
	task_model = Class.new(SimpleTask)

	task_model.executed_by ExecutionAgentModel
	first, second = prepare_plan :missions => 2, :model => task_model
	assert(first.execution_agent)
	assert(ExecutionAgentModel, first.execution_agent.class)
	assert(second.execution_agent)
	assert(ExecutionAgentModel, second.execution_agent.class)

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
	plan.insert(task  = Class.new(SimpleTask).new)
	task.executed_by(agent = ExecutionAgentModel.new)

	agent.start!
	agent.stop!
	assert_raises(Roby::TaskModelViolation) { task.start! }
    end

    def test_initialization
	agent = ExecutionAgentModel.new
	task, (init1, init2) = prepare_plan :missions => 1, :discover => 2, :model => SimpleTask
	task.executed_by agent
	init1.executed_by agent
	init2.executed_by agent

	agent.realized_by(init = (init1 + init2))
	agent.on(:start, init, :start)
	init.forward(:success, agent, :ready)

	# task.start!
	# assert(init1.running?)
	# init1.success!
	# init2.success!
	# assert(agent.event(:ready).happened?)
    end
end

