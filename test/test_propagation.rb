require 'flexmock'
require 'mockups/tasks'
require 'test_config'

require 'roby'

class TC_Propagation < Test::Unit::TestCase
    include RobyTestCommon

    def test_gather_propagation
	e1, e2 = EventGenerator.new(true), EventGenerator.new(true)

	set = Propagation.gather_propagation do
	    e1.call(1)
	    e1.call(4)
	    e2.emit(2)
	    e2.emit(3)
	    assert_raises(Propagation::PropagationException) { e1.emit(nil) }
	    assert_raises(Propagation::PropagationException) { e2.call(nil) }
	end
	assert_equal({ e1 => [false, nil, 1, nil, nil, 4, nil], e2 => [true, nil, 2, nil, nil, 3, nil] }, set)
    end

    def test_delay
	s, e = EventGenerator.new(true), EventGenerator.new(true)
	s.on(e, :delay => 0.1)
	Control.once { s.call(nil) }
	Control.instance.process_events
	assert(!e.happened?)
	sleep(0.2)
	Control.instance.process_events
	assert(e.happened?)
    end

    def test_duplicate_signals
	t = SimpleTask.new # SimpleTask defines a model signal between :start and :success
	
	FlexMock.use do |mock|
	    t.on(:start)   { |event| t.emit(:success, event.context) }
	    t.on(:start)   { |event| t.emit(:success, event.context) }

	    t.on(:success) { |event| mock.success(event.context) }
	    t.on(:stop)    { |event| mock.stop(event.context) }
	    mock.should_receive(:success).with(42).once.ordered
	    mock.should_receive(:stop).with(42).once.ordered
	    t.start!(42)
	end
    end
end

