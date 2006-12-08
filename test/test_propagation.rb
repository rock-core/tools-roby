require 'flexmock'
require 'test_config'

require 'roby/event'
require 'roby/propagation'

class TC_Propagation < Test::Unit::TestCase
    include Roby
    include RobyTestCommon

    def test_gather_propagation
	e1, e2 = EventGenerator.new(true), EventGenerator.new(true)

	set = Propagation.gather_propagation do
	    e1.call(1)
	    e1.call(nil)
	    e2.emit(2)
	    e2.emit(3)
	    assert_raises(Propagation::PropagationException) { e1.emit(nil) }
	    assert_raises(Propagation::PropagationException) { e2.call(nil) }
	end
	assert_equal({ e1 => [false, nil, 1, nil, nil], e2 => [true, nil, 2, nil, 3] }, set)
    end

    # Common code shared by test_signal_handlers_propagation and test_causal_links_propagation
    def simple_propagation_common_test
	Thread.current[:propagation_id] = 0
	s1, s2, e1, e2 = (1..4).map { EventGenerator.new(true) }

	yield(s1, s2, e1, e2)

	initial_set = Propagation.gather_propagation do
	    s1.call(1)
	    s2.call(2)
	end

	set = Propagation.event_propagation_step initial_set, []

	assert(set.has_key?(e1))
	step = set[e1]
	assert_equal(5, step.size)
	assert_equal(false, step[0])
	assert_equal([s1, s2].to_set, step.values_at(1, 3).map { |e| e.generator }.to_set)
	assert_equal([1, 2].to_set, step.values_at(2, 4).to_set)

	assert(set.has_key?(e2))
	step = set[e2]
	assert_equal(3, step.size)
	assert_equal(true, step[0])
	assert_equal(s2, step[1].generator)
	assert_equal(2, step[2])
    end

    def test_signal_handlers_propagation
	simple_propagation_common_test do |s1, s2, e1, e2|
	    s1.on { |e| e1.call(e.context) }
	    s2.on { |e| e1.call(e.context) }
	    s2.on { |e| e2.emit(e.context) }
	end
    end
    def test_causal_links_propagation
	simple_propagation_common_test do |s1, s2, e1, e2|
	    s1.on e1
	    s2.on e1
	    e2.emit_on s2
	end
    end
end

