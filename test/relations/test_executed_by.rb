$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'
require 'flexmock'

class TC_ExecutedBy < Test::Unit::TestCase
    include Roby::Test

    class ExecutionAgentModel < SimpleTask
	event :ready
	forward :start => :ready
    end

    def test_relationships
	plan.add(task = SimpleTask.new)
	exec_task = ExecutionAgentModel.new

	task.executed_by exec_task
	assert_equal(exec_task, task.execution_agent)
    end

    def test_inherits_execution_model
	model = Class.new(Roby::Task) do
	    executed_by ExecutionAgentModel
	end
	submodel = Class.new(model)

	assert_equal(ExecutionAgentModel, submodel.execution_agent)
    end

    def test_nominal
	plan.add(task = SimpleTask.new)
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
	plan.add(task = SimpleTask.new)
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
	plan.add_mission(task = SimpleTask.new)
	exec = Class.new(SimpleTask) do
	    event :ready
	    signal :start => :failed
	end.new
	task.executed_by exec

	assert_original_error(NilClass, EmissionFailed) { task.start! }
	assert(!task.running?)
	assert(!exec.running?)
	assert(exec.finished?)
    end

    def test_agent_model
	task_model = Class.new(SimpleTask)

	task_model.executed_by ExecutionAgentModel
	plan.add_mission(task = task_model.new)
	assert(task.execution_agent)
	assert(ExecutionAgentModel, task.execution_agent.class)

	task.start!
	assert(task.running?)
	assert(task.execution_agent.running?)
    end

    def test_respawn
	task_model = Class.new(SimpleTask)
	task_model.executed_by ExecutionAgentModel
	first, second = prepare_plan :add => 2, :model => task_model
	assert(first.execution_agent)
	assert(ExecutionAgentModel, first.execution_agent.class)
	assert(second.execution_agent)
	assert(ExecutionAgentModel, second.execution_agent.class)
	assert_same(first.execution_agent, second.execution_agent)

	first.start!
	assert(first.running?)
	first_agent = first.execution_agent
	assert(first_agent.running?)

	plan.add(third = task_model.new)
	assert_equal(first.execution_agent, third.execution_agent)

	first.execution_agent.stop!
	assert(first.event(:aborted).happened?)
	assert(first_agent.finished?)
	assert(second.execution_agent)
	assert(second.execution_agent.pending?)
    end

    def test_cannot_respawn
	plan.add_mission(task  = Class.new(SimpleTask).new)
	task.executed_by(agent = ExecutionAgentModel.new)

	agent.start!
	agent.stop!
	assert_raises(CommandFailed) { task.start! }
    end

    def test_initialization
	agent = Class.new(SimpleTask) do
	    event :ready, :command => true
	end.new
	task, (init1, init2) = prepare_plan :missions => 1, :add => 2, :model => SimpleTask
	task.executed_by agent
	init1.executed_by agent
	init2.executed_by agent

	agent.realized_by(init = (init1 + init2))
	agent.signals(:start, init, :start)
	init.forward_to(:success, agent, :ready)

	task.start!
	assert(!task.running?)
	assert(!agent.event(:ready).happened?)
	assert(init1.running?)
	assert(!init2.running?)
	init1.success!
	init2.success!
	assert(agent.event(:ready).happened?)
    end
end
