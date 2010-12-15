$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'
require 'flexmock'

class TC_ExecutedBy < Test::Unit::TestCase
    include Roby::Test

    class ExecutionAgentModel < Tasks::Simple
	event :ready
	forward :start => :ready
    end
    class SecondExecutionModel < Tasks::Simple
	event :ready
	forward :start => :ready
    end

    def test_relationships
	plan.add(task = Tasks::Simple.new)
	exec_task = ExecutionAgentModel.new

	task.executed_by exec_task
	assert_equal(exec_task, task.execution_agent)
    end

    def test_inherits_execution_model
	model = Class.new(Roby::Task) do
	    executed_by ExecutionAgentModel, :id => 20
	end
	submodel = Class.new(model)

	assert_equal([ExecutionAgentModel, {:id => 20}], submodel.execution_agent)
    end

    def test_nominal
	plan.add(task = Tasks::Simple.new)
	task.executed_by(ExecutionAgentModel.new)
	task.executed_by(exec = ExecutionAgentModel.new)

	FlexMock.use do |mock|
	    exec.on(:start) { |ev| mock.agent_started }
	    exec.on(:ready) { |ev| mock.agent_ready }
	    task.on(:start) { |ev| mock.task_started }

	    mock.should_receive(:agent_started).once.ordered
	    mock.should_receive(:agent_ready).once.ordered
	    mock.should_receive(:task_started).once.ordered
	    task.start!
	end

	task.stop!
	assert_nothing_raised { exec.stop! }
    end

    def test_agent_fails
	plan.add(task = Tasks::Simple.new)
	exec = ExecutionAgentModel.new
	task.executed_by exec
	task.start!

	FlexMock.use do |mock|
	    task.on(:aborted) { |ev| mock.aborted }
	    mock.should_receive(:aborted).once
	    exec.stop!
	end
	assert(!task.running?)
    end

    def test_agent_start_failed
	plan.add_permanent(task = Tasks::Simple.new)
	exec = Class.new(Tasks::Simple) do
	    event :ready
	    signal :start => :failed
	end.new
	task.executed_by exec

	assert_original_error(NilClass, EmissionFailed) { task.start! }
	assert(task.failed?)
	assert(exec.finished?)
    end

    def test_agent_model_spawns
	task_model = Class.new(Tasks::Simple)

	task_model.executed_by ExecutionAgentModel, :id => 10
	plan.add_mission(task = task_model.new)
	assert(task.execution_agent)
        assert_equal(10, task.execution_agent.arguments[:id])
	assert_kind_of(ExecutionAgentModel, task.execution_agent)

	task.start!
	assert(task.running?)
	assert(task.execution_agent.running?)
    end

    def test_agent_model_reuses
        plan.add_permanent(agent = ExecutionAgentModel.new)

	task_model = Class.new(Tasks::Simple)
	task_model.executed_by ExecutionAgentModel

	plan.add_mission(task = task_model.new)
	assert_same(agent, task.execution_agent)

	task.start!
	assert(task.running?)
	assert(task.execution_agent.running?)
    end

    def test_agent_model_reuses_running_agent
        plan.add_permanent(agent = ExecutionAgentModel.new)
        agent.start!

	task_model = Class.new(Tasks::Simple)
	task_model.executed_by ExecutionAgentModel

	plan.add_mission(task = task_model.new)
	assert_same(agent, task.execution_agent)

	task.start!
	assert(task.running?)
    end

    def test_agent_model_arguments
        plan.add_permanent(agent1 = ExecutionAgentModel.new(:id => 1))
        plan.add_permanent(agent2 = ExecutionAgentModel.new(:id => 2))

	task_model = Class.new(Tasks::Simple)
	task_model.executed_by ExecutionAgentModel, :id => 2

	plan.add_mission(task = task_model.new)
	assert_same(agent2, task.execution_agent)

	task.start!
	assert(task.running?)
	assert(task.execution_agent.running?)
    end

    def test_task_has_wrong_agent
	task_model = Class.new(Tasks::Simple)
	task_model.executed_by ExecutionAgentModel, :id => 2

        # Wrong agent type
	plan.add_permanent(task = task_model.new)
        plan.remove_object(task.execution_agent)
        task.executed_by SecondExecutionModel.new(:id => 2)
        task.start!
        assert task.failed?
        assert_kind_of CommandFailed, task.failure_reason

        # Wrong agent arguments
	plan.add_permanent(task = task_model.new)
        plan.remove_object(task.execution_agent)
        task.executed_by ExecutionAgentModel.new(:id => 3)
        task.start!
        assert task.failed?
        assert_kind_of CommandFailed, task.failure_reason
    end

    def test_model_requires_agent_but_none_exists
	task_model = Class.new(Tasks::Simple)
	task_model.executed_by ExecutionAgentModel, :id => 2

	plan.add_permanent(task = task_model.new)
        plan.remove_object(task.execution_agent)

        task.start!
        assert task.failed?
        assert_kind_of CommandFailed, task.failure_reason
    end

    def test_respawn
	task_model = Class.new(Tasks::Simple)
	task_model.executed_by ExecutionAgentModel
	first, second = prepare_plan :add => 2, :model => task_model
	assert(first.execution_agent)
	assert_kind_of(ExecutionAgentModel, first.execution_agent)
	assert(second.execution_agent)
	assert_kind_of(ExecutionAgentModel, second.execution_agent)
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
	plan.add_permanent(task  = Class.new(Tasks::Simple).new)
	task.executed_by(agent = ExecutionAgentModel.new)

	agent.start!
	agent.stop!
	task.start!
        assert(task.failed?)
        assert_kind_of CommandFailed, task.failure_reason
    end

    def test_initialization
	agent = Class.new(Tasks::Simple) do
	    event :ready, :command => true
	end.new
	task, (init1, init2) = prepare_plan :missions => 1, :add => 2, :model => Tasks::Simple
	task.executed_by agent
	init1.executed_by agent
	init2.executed_by agent

	agent.depends_on(init = (init1 + init2))
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

    def test_replacement
	agent = Class.new(Tasks::Simple) do
	    event :ready, :command => true
	end.new
	root, (task, replacement) = prepare_plan :missions => 1, :add => 2, :model => Tasks::Simple

        root.depends_on task, :model => Tasks::Simple
	task.executed_by agent
        plan.replace_task(task, replacement)

        assert_equal agent, replacement.execution_agent
        assert replacement.used_with_an_execution_agent?

        agent.start!
        agent.ready!
        replacement.start!
        agent.stop!
        assert replacement.aborted?
    end
end

