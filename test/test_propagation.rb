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

    def test_prepare_propagation
	e1, e2 = EventGenerator.new(true), EventGenerator.new(true)

	step = [nil, 1, nil, nil, 4, nil]
	sources, context = Propagation.prepare_propagation(nil, false, step)
	assert_equal([], sources)
	assert_equal([1, 4].to_set, context.to_set)

	step = [nil, nil, nil, nil, 4, nil]
	sources, context = Propagation.prepare_propagation(nil, false, step)
	assert_equal([], sources)
	assert_equal(4, context)

	step = [e1, nil, nil, nil, nil, nil]
	sources, context = Propagation.prepare_propagation(nil, false, step)
	assert_equal([e1], sources)
	assert_equal(nil, context)
    end

    def test_precedence_graph
	e1, e2 = EventGenerator.new(true), EventGenerator.new(true)
	Roby.plan.discover e1
	Roby.plan.discover e2
	Propagation.event_ordering << :bla

	e1.signal e2
	assert(EventStructure::Precedence.linked?(e1, e2))
	assert(Propagation.event_ordering.empty?)

	Propagation.event_ordering << :bla
	e1.remove_signal e2
	assert(Propagation.event_ordering.empty?)
	assert(!EventStructure::Precedence.linked?(e1, e2))
    end


    def test_next_step
	# For the test to be valid, we need +pending+ to have a deterministic ordering
	# Fix that here
	e1, e2 = EventGenerator.new(true), EventGenerator.new(true)
	pending = [ [e1, [true, nil, nil, nil]], [e2, [false, nil, nil, nil]] ]
	def pending.each_key; each { |(k, v)| yield(k) } end
	def pending.delete(ev); delete_if { |(k, v)| k == ev } end

	e1.add_precedence e2
	assert_equal(e1, Propagation.next_event(pending).first)

	e1.remove_precedence e2
	e2.add_precedence e1
	assert_equal(e2, Propagation.next_event(pending).first)
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

    def test_signal_forward
	forward = EventGenerator.new(true)
	signal  = EventGenerator.new(true)

	FlexMock.use do |mock|
	    ev = EventGenerator.new do |ev|
		mock.command_called
	    end
	    ev.on { mock.handler_called }

	    ev.emit_on forward
	    signal.on  ev

	    seed = lambda do
		forward.call
		signal.call
	    end
	    mock.should_receive(:handler_called).once.ordered
	    mock.should_receive(:command_called).once.ordered
	    Propagation.propagate_events([seed])
	    STDERR.puts Propagation.delayed_events.inspect
	    Control.instance.process_events
	    Control.instance.process_events
	end
    end
end

