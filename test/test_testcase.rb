$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/testcase'
require 'mockups/tasks'
require 'flexmock'

class TC_Test_TestCase < Test::Unit::TestCase 
    include Roby::Test
    include Roby::Test::Assertions

    def test_assert_any_event
	plan.discover(t = SimpleTask.new)
	t.start!
	assert_nothing_raised do
	    assert_any_event(t.event(:start))
	end

	t.success!
	assert_nothing_raised do
	    assert_any_event(t.event(:start))
	    assert_any_event([t.event(:success)], [t.event(:stop)])
	end

	plan.discover(t = SimpleTask.new)
	t.start!
	t.failed!
	assert_raises(Test::Unit::AssertionFailedError) do
	    assert_any_event([t.event(:success)], [t.event(:stop)])
	end

	Roby.logger.level = Logger::FATAL
	Roby.control.run :detach => true
	plan.insert(t = SimpleTask.new)
	assert_any_event(t.event(:success)) do 
	    t.start!
	    t.success!
	end

	# Make control quit and check that we get ControlQuitError
	plan.insert(t = SimpleTask.new)
	assert_raises(Test::Unit::AssertionFailedError) do
	    assert_any_event(t.event(:success)) do
		t.start!
		t.failed!
	    end
	end

	## Same test, but check that the assertion succeeds since we *are*
	## checking that +failed+ happens
	Roby.control.run :detach => true
	plan.insert(t = SimpleTask.new)
	assert_nothing_raised do
	    assert_any_event(t.event(:failed)) do
		t.start!
		t.failed!
	    end
	end
    end

    def test_assert_succeeds
	Roby.control.run :detach => true
    
	task = Class.new(SimpleTask) do
	    forward :start => :success
	end.new
	assert_nothing_raised do
	    assert_succeeds(task)
	end

	task = Class.new(SimpleTask) do
	    forward :start => :failed
	end.new
	assert_raises(Test::Unit::AssertionFailedError) do
	    assert_succeeds(task)
	end
    end
end

