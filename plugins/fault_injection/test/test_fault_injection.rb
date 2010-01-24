$LOAD_PATH.unshift File.expand_path( '..', File.dirname(__FILE__))
require 'test/unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/tasks/simple_task'
require 'fault_injection'

class TC_FaultInjection < Test::Unit::TestCase
    include Roby::Test
    include Roby::Test::Assertions

    def test_inject_fault
        model = Class.new(Roby::Test::SimpleTask) do
            event :specialized_fault
            forward :specialized_fault => :failed
        end
        plan.add_permanent(task = model.new)

        engine.run

        assert_any_event(task.start_event) do
	    assert_raises(ArgumentError) { task.inject_fault(:start) }
	    task.start!
	end

	fake_task = nil
	assert_any_event(task.stop_event) do
	    assert_raises(ArgumentError) { task.inject_fault(:updated_data) }
	    assert_nothing_raised { task.inject_fault(:specialized_fault) }
	    assert_equal(2, plan.known_tasks.size)
	    fake_task = plan.known_tasks.find { |t| t != task }
	end

	assert(fake_task.finished?)
	assert(fake_task.event(:specialized_fault).happened?)
    end

    def test_apply
	model = Class.new(Roby::Test::SimpleTask) do
	    event :specialized_fault
	    forward :specialized_fault => :failed
	end

	fault_models = Hash.new { |h, k| h[k] = Hash.new }
	fault_models[model][:specialized_fault] = FaultInjection::Rate.new(0.01, 1.0)
	fault_models[Roby::Test::SimpleTask][:stop] = FaultInjection::Rate.new(1_000_000, 1.0)
        plan.add_permanent(simple = Roby::Test::SimpleTask.new)
        plan.add_permanent(specialized = model.new)
        both_started = simple.start_event & specialized.start_event
	
        engine.run

        assert_any_event(both_started) do
	    simple.start!
	    specialized.start!
	end

        fake_specialized = engine.execute do
	    result = Roby::FaultInjection.apply(fault_models, plan)
	    assert_equal(1, result.size)
	    result.first.last
	end
	engine.wait_one_cycle

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

