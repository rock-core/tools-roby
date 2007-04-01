$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'mockups/tasks'

class TC_Propagation < Test::Unit::TestCase
    include Roby::Test

    def test_gather_propagation
	e1, e2, e3 = EventGenerator.new(true), EventGenerator.new(true), EventGenerator.new(true)
	plan.discover [e1, e2, e3]

	set = Propagation.gather_propagation do
	    e1.call(1)
	    e1.call(4)
	    e2.emit(2)
	    e2.emit(3)
	    e3.call(5)
	    e3.emit(6)
	end
	assert_equal({ e1 => [nil, [nil, 1, nil, nil, 4, nil]], e2 => [[nil, 2, nil, nil, 3, nil], nil], e3 => [[nil, 6, nil], [nil, 5, nil]] }, set)
    end

    def test_prepare_propagation
	e1, e2 = EventGenerator.new(true), EventGenerator.new(true)

	step = [nil, 1, nil, nil, 4, nil]
	sources, context = Propagation.prepare_propagation(nil, false, step)
	assert_equal([nil, nil], sources)
	assert_equal([1, 4], context)

	step = [nil, nil, nil, nil, 4, nil]
	sources, context = Propagation.prepare_propagation(nil, false, step)
	assert_equal([nil, nil], sources)
	assert_equal([nil, 4], context)

	step = [e1, nil, nil, nil, nil, nil]
	sources, context = Propagation.prepare_propagation(nil, false, step)
	assert_equal([e1, nil], sources)
	assert_equal([nil, nil], context)
    end

    def test_precedence_graph
	e1, e2 = EventGenerator.new(true), EventGenerator.new(true)
	Propagation.event_ordering << :bla
	Roby.plan.discover e1
	Roby.plan.discover e2
	assert(Propagation.event_ordering.empty?)
	
	task = Roby::Task.new
	Roby.plan.discover(task)
	assert(Propagation.event_ordering.empty?)
	assert(EventStructure::Precedence.linked?(task.event(:start), task.event(:failed)))

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
	plan.discover [e1, e2]
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
	plan.insert(t = SimpleTask.new)
	e = EventGenerator.new(true)
	t.event(:start).on e, :delay => 0.1
	Control.once { t.start! }
	process_events
	assert(!e.happened?)
	sleep(0.2)
	process_events
	assert(e.happened?)
    end

    def test_duplicate_signals
	plan.insert(t = SimpleTask.new)
	
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
    def test_diamond_structure
	a = Class.new(SimpleTask) do
	    event :child_success
	    event :child_stop
	    forward :child_success => :child_stop
	end.new(:id => 'a')

	plan.insert(a)
	a.realized_by(b = SimpleTask.new(:id => 'b'))

	b.forward(:success, a, :child_success)
	b.forward(:stop, a, :child_stop)

	FlexMock.use do |mock|
	    a.on(:child_stop) { mock.stopped }
	    mock.should_receive(:stopped).twice.ordered
	    a.start!
	    b.start!
	    b.success!
	end
    end

    def test_signal_forward
	forward = EventGenerator.new(true)
	signal  = EventGenerator.new(true)
	plan.discover [forward, signal]

	FlexMock.use do |mock|
	    sink = EventGenerator.new do |context|
		mock.command_called(context)
		sink.emit(42)
	    end
	    sink.on { |event| mock.handler_called(event.context) }

	    forward.forward sink
	    signal.signal   sink

	    seed = lambda do
		forward.call(24)
		signal.call(42)
	    end
	    mock.should_receive(:command_called).with(42).once.ordered
	    mock.should_receive(:handler_called).with(42).once.ordered
	    mock.should_receive(:handler_called).with(24).once.ordered
	    Propagation.propagate_events([seed])
	end
    end
end

