require 'test_config'
require 'mockups/tasks'
require 'flexmock'

require 'roby/relations/executed_by'

class TC_ExecutedBy < Test::Unit::TestCase
    include Roby
    include RobyTestCommon

    attr_reader :plan
    def setup
	@plan = Plan.new
	super
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

    def test_agent_fails
	task = SimpleTask.new
	exec = Class.new(SimpleTask) do
	    event(:start, :command => true)
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

    def test_aborted_default_handler
	klass = Class.new(SimpleTask) do
	    event(:ready, :command => true)
	end

	t1, t2, t3 = klass.new, klass.new, klass.new
	t1.add_child(t2)
	t1.executed_by(t3)

	FlexMock.use do |mock|
	    t1.on(:start) { mock.t1_start }
	    t2.on(:stop) { mock.t2_stop }

	    t3.event(:aborted).on { mock.t3 }
	    t1.event(:aborted).on { mock.t1 }

	    mock.should_receive(:t1_start).once.ordered
	    mock.should_receive(:t2_stop).never
	    mock.should_receive(:t3).once.ordered
	    mock.should_receive(:t1).once.ordered

	    t3.start!
	    t1.start!
	    t2.start!
	    t3.ready!
	    t3.emit(:aborted, nil)
	end
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
	plan.insert(task)

	task.start!
	assert(task.execution_agent)
	assert(exec_model, task.execution_agent.class)

	assert(task.running?)
	assert(task.execution_agent.running?)
    end
end

