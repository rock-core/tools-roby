$LOAD_PATH.unshift File.expand_path( '..', File.dirname(__FILE__))
require 'test/unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/tasks/simple_task'
require 'fault_injection'

class TC_FaultInjection < Test::Unit::TestCase
    include Roby::Test

    def test_inject_fault
	Roby.control.run :detach => true

	task = nil
	Roby.execute do
	    model = Class.new(Roby::Test::SimpleTask) do
		event :specialized_fault
		forward :specialized_fault => :failed
	    end

	    plan.permanent(task = model.new)
	    assert_raises(ArgumentError) { task.inject_fault(:start) }

	    task.start!
	end
	Roby.wait_one_cycle

	fake_task = nil
	Roby.execute do
	    assert_raises(ArgumentError) { task.inject_fault(:updated_data) }
	    assert_nothing_raised { task.inject_fault(:specialized_fault) }
	    assert_equal(2, plan.known_tasks.size)
	    fake_task = plan.known_tasks.find { |t| t != task }
	end
	Roby.wait_one_cycle

	assert(fake_task.finished?)
	assert(fake_task.event(:specialized_fault).happened?)
    end

    def test_apply
	Roby.control.run :detach => true

	model = Class.new(Roby::Test::SimpleTask) do
	    event :specialized_fault
	    forward :specialized_fault => :failed
	end

	fault_models = Hash.new { |h, k| h[k] = Hash.new }
	fault_models[model][:specialized_fault] = FaultInjection::Rate.new(0.01, 1.0)
	fault_models[Roby::Test::SimpleTask][:stop] = FaultInjection::Rate.new(1_000_000, 1.0)
	
	simple, specialized = nil
	Roby.execute do
	    plan.permanent(simple = Roby::Test::SimpleTask.new)
	    plan.permanent(specialized = model.new)
	    simple.start!
	    specialized.start!
	end
	Roby.wait_one_cycle

	sleep(0.5)
	fake_specialized = nil
	Roby.execute do
	    result = Roby::FaultInjection.apply(fault_models)
	    assert_equal(1, result.size)
	    fake_specialized = result.first.last
	end
	Roby.wait_one_cycle

	assert(simple.running?)
	assert(specialized.finished?)
	assert(fake_specialized.finished?)
	assert(fake_specialized.event(:specialized_fault).happened?)
    end

    def test_task_lifetime
	plan.discover(task = Roby::Test::SimpleTask.new)
	task.start!
	sleep(0.5)
	assert(task.lifetime > 0.5)
    end
end

