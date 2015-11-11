require 'roby/test/self'

class TC_ExecutedBy < Minitest::Test
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
	model = Roby::Task.new_submodel do
	    executed_by ExecutionAgentModel, :id => 20
	end
	submodel = model.new_submodel

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
            exec.start!
	    task.start!
	end

	task.stop!
	exec.stop!
    end

    def test_agent_fails
	plan.add(task = Tasks::Simple.new)
	task.executed_by(exec = ExecutionAgentModel.new)
        task.execution_agent
        exec.start!
        exec.ready_event.emit
	task.start!

        recorder = flexmock
        task.aborted_event.on { |ev| recorder.called }
        recorder.should_receive(:called).once
        exec.stop!
	assert(!task.running?)
    end

    def test_task_has_wrong_agent
	task_model = Tasks::Simple.new_submodel
	task_model.executed_by ExecutionAgentModel, id: 2

        # Wrong agent type
	plan.add(task = task_model.new)
        assert_raises(Roby::ModelViolation) do
            task.executed_by SecondExecutionModel.new(:id => 2)
        end
        assert !task.execution_agent

        # Wrong agent arguments
	plan.add(task = task_model.new)
        assert_raises(Roby::ModelViolation) do
            task.executed_by SecondExecutionModel.new(:id => 2)
        end
        assert !task.execution_agent
    end

    def test_model_requires_agent_but_none_exists
	task_model = Tasks::Simple.new_submodel
	task_model.executed_by ExecutionAgentModel, :id => 2
	plan.add(task = task_model.new)
        assert_raises(Roby::CommandFailed) { task.start! }
        assert task.failed_to_start?
        assert_kind_of CommandFailed, task.failure_reason
    end

    def test_as_plan
        model = Tasks::Simple.new_submodel do
	    event :ready, :controlable => true
            def self.as_plan
                new(:id => 10)
            end
        end
        root = prepare_plan :add => 1, :model => Tasks::Simple
        agent = root.executed_by(model)
        assert_kind_of model, agent
        assert_equal 10, agent.arguments[:id]
    end
end

