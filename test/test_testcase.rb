require 'roby/test/self'
require 'roby/test/testcase'

class TC_Test_TestCase < Minitest::Test 
    Assertion = MiniTest::Assertion
    
    def test_assert_event_emission
	plan.add(t = Tasks::Simple.new)
	t.start!
        assert_event_emission(t.event(:start))

	t.success!
        assert_event_emission(t.event(:start))
        assert_event_emission([t.event(:success)], [t.event(:stop)])

	plan.add(t = Tasks::Simple.new)
	t.start!
	t.failed!
	assert_raises(Assertion) do
	    assert_event_emission([t.event(:success)], [t.event(:stop)])
	end

	Roby.logger.level = Logger::FATAL
        Robot.logger.level = Logger::FATAL
	engine.run
	plan.add_permanent_task(t = Tasks::Simple.new)
	assert_event_emission(t.event(:success)) do 
	    t.start!
	    t.success!
	end

	plan.add_permanent_task(t = Tasks::Simple.new)
	assert_raises(Assertion) do
	    assert_event_emission(t.event(:success)) do
		t.start!
		t.failed!
	    end
	end

	## Same test, but check that the assertion succeeds since we *are*
	## checking that +failed+ happens
	plan.add_permanent_task(t = Tasks::Simple.new)
        assert_event_emission(t.event(:failed)) do
            t.start!
            t.failed!
        end
    end

    def test_assert_event_emission_events_given_by_block
        assert_event_emission do
            plan.add(t = Tasks::Simple.new)
            t.start!
            t.start_event
        end
    end

    def test_assert_succeeds
	engine.run
    
	task = Tasks::Simple.new_submodel do
	    forward start: :success
	end.new
        assert_succeeds(task)

	task = Tasks::Simple.new_submodel do
	    forward start: :failed
	end.new
	assert_raises(Assertion) do
	    assert_succeeds(task)
	end
    end

    def test_sampling
	engine.run

	i = 0
        # Sampling of 1s, every 100ms (== 1 cycle)
	samples = Roby::Test.sampling(engine, 1, 0.1, :time_test, :index, :dummy) do
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
	stats = Roby::Test.stats(samples, dummy: :absolute)
	assert_in_delta(1, stats.index.mean, 0.05)
	assert_in_delta(0.025, stats.index.stddev, 0.1)
	assert_in_delta(1, stats.dummy.mean, 0.05)
	assert_in_delta(0.025, stats.dummy.stddev, 0.1)
	assert_in_delta(0.1, stats.dt.mean, 0.001, stats.dt)
	assert_in_delta(0, stats.dt.stddev, 0.001)

	stats = Roby::Test.stats(samples, index: :rate, dummy: :absolute_rate)
	assert_in_delta(10, stats.index.mean,  1)
	assert_in_delta(0.25, stats.index.stddev, 0.5)
	assert_in_delta(10, stats.dummy.mean,  1)
	assert_in_delta(0.25, stats.dummy.stddev, 0.5)
    end
end

