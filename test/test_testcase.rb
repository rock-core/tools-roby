$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/testcase'
require 'mockups/tasks'
require 'flexmock'

class TC_Task < Test::Unit::TestCase 
    include Roby::Test
    include Roby::Test::Assertions

    def test_assert_events
	plan.discover(t = SimpleTask.new)
	t.start!
	assert_nothing_raised do
	    assert_events(t.event(:start))
	end

	t.success!
	assert_nothing_raised do
	    assert_events(t.event(:start))
	    assert_events([t.event(:success)], [t.event(:stop)])
	end

	plan.discover(t = SimpleTask.new)
	t.start!
	t.failed!
	assert_raises(Test::Unit::AssertionFailedError) do
	    assert_events([t.event(:success)], [t.event(:stop)])
	end

	Roby.logger.level = Logger::DEBUG
	Roby.control.run :detach => true
	plan.insert(t = SimpleTask.new)

	main = Thread.current
	watchdog = Thread.new do
	    # Wait for the main thread to acquire the lock and start the task
	    wait_thread_stopped(main)
	    Roby::Control.once do 
		t.start!
		t.success!
	    end
	end
	assert_events([t.event(:success)], [t.event(:stop)])
	watchdog.join

	# Make control quit and check what assert_events does
	plan.insert(t = SimpleTask.new)
	main = Thread.current
	watchdog = Thread.new do
	    # Wait for the main thread to acquire the lock and start the task
	    wait_thread_stopped(main)
	    Roby::Control.once do 
		t.start!
		t.failed!
	    end
	end
	assert_events([t.event(:success)], [t.event(:stop)])
	watchdog.join
    end

    def test_assert_succeeds
	Roby.control.run :detach => true
	model = Class.new(SimpleTask) do
	    forward :start => :success
	end
	task = model.new

	assert_nothing_raised do
	    assert_succeeds(task)
	end
    end
end

