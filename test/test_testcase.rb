$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/testcase'
require 'roby/test/tasks/simple_task'
require 'flexmock'

class TC_Test_TestCase < Test::Unit::TestCase 
    include Roby::Test
    include Roby::Test::Assertions

    Assertion = if defined?(MiniTest::Assertion)
                    MiniTest::Assertion
                else
                    Test::Unit::AssertionFailedError
                end
    
    def setup
        Roby.app.setup_global_singletons

        @plan    = Roby.plan
        @control = Roby.control
        @engine  = Roby.engine
        super
    end

    def test_assert_any_event
	plan.add(t = SimpleTask.new)
	t.start!
	assert_nothing_raised do
	    assert_any_event(t.event(:start))
	end

	t.success!
	assert_nothing_raised do
	    assert_any_event(t.event(:start))
	    assert_any_event([t.event(:success)], [t.event(:stop)])
	end

	plan.add(t = SimpleTask.new)
	t.start!
	t.failed!
	assert_raises(Assertion) do
	    assert_any_event([t.event(:success)], [t.event(:stop)])
	end

	Roby.logger.level = Logger::FATAL
        Robot.logger.level = Logger::FATAL
	engine.run
	plan.add_permanent(t = SimpleTask.new)
	assert_any_event(t.event(:success)) do 
	    t.start!
	    t.success!
	end

	plan.add_permanent(t = SimpleTask.new)
	assert_raises(Assertion) do
	    assert_any_event(t.event(:success)) do
		t.start!
		t.failed!
	    end
	end

	## Same test, but check that the assertion succeeds since we *are*
	## checking that +failed+ happens
	plan.add_permanent(t = SimpleTask.new)
	assert_nothing_raised do
	    assert_any_event(t.event(:failed)) do
		t.start!
		t.failed!
	    end
	end
    end

    def test_assert_succeeds
	engine.run
    
	task = Class.new(SimpleTask) do
	    forward :start => :success
	end.new
	assert_nothing_raised do
	    assert_succeeds(task)
	end

	task = Class.new(SimpleTask) do
	    forward :start => :failed
	end.new
	assert_raises(Assertion) do
	    assert_succeeds(task)
	end
    end

    def test_sampling
	engine.run

	i = 0
        # Sampling of 1s, every 100ms (== 1 cycle)
	samples = Roby::Test.sampling(1, 0.1, :time_test, :index, :dummy) do
	    i += 1
	    [engine.cycle_start, i + rand / 10 - 0.05, rand / 10 + 0.95]
	end
	cur_size = samples.size

	# Check the result
	samples.each { |a| assert_equal(a.time_test, a.t) }
	samples.each_with_index do |a, i|
	    next if i == 0
	    assert(a.dt)
	    assert_in_delta(0.1, a.dt, 0.01)
	end
	samples.each_with_index do |a, b| 
	    assert_in_delta(b + 1, a.index, 0.05)
	end

	# Check that the handler has been removed
	assert_equal(cur_size, samples.size)

	samples
    end

    def test_stats
	samples = test_sampling
	stats = Roby::Test.stats(samples, :dummy => :absolute)
	assert_in_delta(1, stats.index.mean, 0.05)
	assert_in_delta(0.025, stats.index.stddev, 0.1)
	assert_in_delta(1, stats.dummy.mean, 0.05)
	assert_in_delta(0.025, stats.dummy.stddev, 0.1)
	assert_in_delta(0.1, stats.dt.mean, 0.001, stats.dt)
	assert_in_delta(0, stats.dt.stddev, 0.001)

	stats = Roby::Test.stats(samples, :index => :rate, :dummy => :absolute_rate)
	assert_in_delta(10, stats.index.mean,  1)
	assert_in_delta(0.25, stats.index.stddev, 0.5)
	assert_in_delta(10, stats.dummy.mean,  1)
	assert_in_delta(0.25, stats.dummy.stddev, 0.5)
    end
end

