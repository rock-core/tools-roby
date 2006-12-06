require 'flexmock'
require 'test_config'
require 'roby/control'
require 'mockups/tasks'

class TC_Event < Test::Unit::TestCase
    include Roby
    include RobyTestCommon

    def test_properties
	event = EventGenerator.new
	assert(! event.respond_to?(:call))
	assert(! event.controlable?)

	event = EventGenerator.new(true)
	assert(event.respond_to?(:call))
	assert(event.controlable?)

	# Check command & emission behavior for controlable events
	FlexMock.use do |mock|
	    event = EventGenerator.new { |context| mock.call_handler(context); event.emit(context) }
	    event.on { |event| mock.event_handler(event.context) }

	    assert(event.respond_to?(:call))
	    assert(event.controlable?)
	    mock.should_receive(:call_handler).once.with(42)
	    mock.should_receive(:event_handler).once.with(42)
	    event.call(42)
	end

	# Check emission behavior for non-controlable events
	FlexMock.use do |mock|
	    event = EventGenerator.new
	    event.on { |event| mock.event(event.context) }
	    mock.should_receive(:event).once.with(42)
	    event.emit(42)
	end
    end

    def test_executable
	event = EventGenerator.new(true)
	event.executable = false
	assert_raises(EventNotExecutable) { event.call(nil) }
	assert_raises(EventNotExecutable) { event.emit(nil) }

	event.executable = true
	assert_nothing_raised { event.call(nil) }
	assert_nothing_raised { event.emit(nil) }

	other = EventGenerator.new(true)
	other.executable = false
	event.on other
	assert_raises(EventNotExecutable) { event.call(nil) }

	event.remove_signal(other)
	assert_nothing_raised { event.emit(nil) }
	other.emit_on event
	assert_raises(EventNotExecutable) { event.call(nil) }

	event.remove_forwarding(other)
	assert_nothing_raised { event.emit(nil) }
	event.on { other.emit(nil) }
	assert_raises(EventNotExecutable) { event.call(nil) }
    end

    def test_emit_failed
	event = EventGenerator.new
	assert_raises(EventModelViolation) { event.emit_failed }
	assert_raises(EventModelViolation) { event.emit_failed("test") }

	klass = Class.new(EventModelViolation)
	assert_raises(klass) { event.emit_failed(klass) }
	assert_raises(klass) { event.emit_failed(klass, "test") }
	begin; event.emit_failed(klass, "test")
	rescue klass => e
	    assert( e.message =~ /: test$/ )
	end

	exception = klass.new(event)
	assert_raises(klass) { event.emit_failed(exception, "test") }
	begin; event.emit_failed(exception, "test")
	rescue klass => e
	    assert_equal(event, e.generator)
	    assert( e.message =~ /: test$/ )
	end

	event = EventGenerator.new { }
	event.call
	assert(event.pending?)
	assert_raises(EventModelViolation) { event.emit_failed }
	assert(!event.pending?)
    end

    def test_propagation_id
	e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)
	e1.on e2
	e1.emit(nil)
	assert_equal(e1.last.propagation_id, e2.last.propagation_id)

	e2.emit(nil)
	assert(e1.last.propagation_id < e2.last.propagation_id)

	e3 = EventGenerator.new(true)
	e3.emit(nil)
	assert(e1.last.propagation_id < e3.last.propagation_id)
	assert(e2.last.propagation_id < e3.last.propagation_id)
    end


    def test_signal_relation
	e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)

	e1.on e2
	assert( e1.child_object?( e2, EventStructure::Signal ))
	assert( e2.parent_object?( e1, EventStructure::Signal ))

	e1.call(nil)
	assert(e2.happened?)
    end
 
    def test_handlers
	e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)
	e1.on { e2.call(nil) }

	FlexMock.use do |mock|
	    e1.on { mock.e1 }
	    e2.on { mock.e2 }
	    mock.should_receive(:e1).once.ordered
	    mock.should_receive(:e2).once.ordered
	    e1.call(nil)
	end
    end

    def test_simple_signal_handler_ordering
	e1, e2, e3 = 4.enum_for(:times).map { EventGenerator.new(true) }
	e1.on(e2)
	e1.on { e2.remove_signal(e3) }
	e2.on(e3)

	e1.call(nil)
	assert( e2.happened? )
	assert( !e3.happened? )
    end

    def test_event_hooks
        FlexMock.use do |mock|
	    hooks = [:calling, :fired, :called]
            mod = Module.new do
		hooks.each do |name|
		    define_method(name) do |context|
			mock.send(name, self)
		    end
        	end
            end

            generator = Class.new(EventGenerator) do
		include mod
	    end.new(true)
            
	    hooks.each do |name|
		mock.should_receive(name).once.with(generator).ordered
	    end
            generator.call(nil)
        end
    end

    def test_postpone
	# Simple postpone behavior
	FlexMock.use do |mock|
	    wait_for = EventGenerator.new(true)
	    event = EventGenerator.new(true)
	    event.singleton_class.class_eval do
		define_method(:calling) do |context|
		    super if defined? super
		    postpone(wait_for, "bla") {}
		end
	    end

	    event.on { mock.event }
	    mock.should_receive(:event).never
	    event.call(nil)
	    assert(! event.happened? )
	    assert(! event.pending? )
	end

	# Test propagation when the block given to postpone 
	# signals some events
        FlexMock.use do |mock|
	    wait_for = EventGenerator.new(true)
	    event = EventGenerator.new(true)
	    event.singleton_class.class_eval do
		define_method(:calling) do |context|
		    super if defined? super
		    if !wait_for.happened?
			postpone(wait_for, "bla") do
			    wait_for.call(nil)
			end
		    end
		end
	    end

	    wait_for.on { mock.wait_for }
	    event.on { mock.event }
	    
	    mock.should_receive(:wait_for).once.ordered
	    mock.should_receive(:event).once.ordered
	    event.call(nil)
        end
    end

    def test_can_signal
	a, b = EventGenerator.new(true), EventGenerator.new
	assert_raises(EventModelViolation) { a.on b }
	assert_nothing_raised { b.emit_on a }

	a = EventGenerator.new(true)
	def a.can_signal?(generator); true end
	assert_nothing_raised { a.on b }
	assert_nothing_raised { a.call(nil) }

	a, b = EventGenerator.new(true), EventGenerator.new
	def a.can_signal?(generator); true end
	a.on b
	def a.can_signal?(generator); false end
	assert_raise(EventModelViolation) { a.call(nil) }
    end

    def test_emit_on
	e1, e2 = [nil,nil].map { EventGenerator.new(true) }
	e1.emit_on e2
        FlexMock.use do |mock|
	    e1.on { mock.e1 }
	    e2.on { mock.e2 }
	    mock.should_receive(:e2).once.ordered
	    mock.should_receive(:e1).once.ordered
	    e2.call(nil)
	end
    end

    def setup_event_aggregator(aggregator)
	events = 10.enum_for(:times).map { EventGenerator.new(true) }
	events.each { |ev| aggregator << ev }
	events.each do |ev| 
	    ev.call(nil)
	    if ev != events[-1]
		yield
	    end
	end
    end

    def test_or_generator
	or_event = OrGenerator.new
	setup_event_aggregator(or_event) do
	    assert(or_event.happened?)
	end

	# Check the behavior of the | operator
	e1, e2, e3, e4 = 4.enum_for(:times).map { EventGenerator.new(true) }
	or_event = e1 | e2
	or_or = or_event | e3
	assert_equal(or_event, or_or)
	or_or = e4 | or_event
	assert_equal(or_event, or_or)
    end

    def test_and_generator
	and_event = AndGenerator.new
	setup_event_aggregator(and_event) do
	    assert(!and_event.happened?)
	end
	assert(and_event.happened?)
	
	# Check the behavior of the & operator
	e1, e2, e3, e4 = (1..4).map { EventGenerator.new(true) }
	and_event = e1 & e2
	and_and = and_event & e3
	assert_equal(and_event, and_and)
	assert_equal([e1, e2, e3].to_set, and_event.waiting.to_set)
	and_and = e4 & and_event
	assert_equal(and_event, and_and)
	assert_equal([e4, e1, e2, e3].to_set, and_event.waiting.to_set)

	# Check dynamic behaviour
	a, b, c = (1..3).map { EventGenerator.new(true) }
        and_event = a & b
        and_event.on c
        assert_equal([and_event], a.enum_for(:each_signal).to_a)
        assert_equal([and_event], b.enum_for(:each_signal).to_a)
        assert_equal([c], and_event.enum_for(:each_signal).to_a)
	a.call(nil)
	assert_equal([b], and_event.waiting)
	assert(! and_event.happened?)
	b.call(nil)
	assert_equal([], and_event.waiting)
	assert(and_event.waiting.empty?)
	assert(and_event.happened?)
    end

    def test_forwarder
	e1 = EventGenerator.new(true)
	forwarder = ForwarderGenerator.new(e1)
	assert(forwarder.controlable?)

	e2 = EventGenerator.new(false)
	forwarder << e2
	assert(!forwarder.controlable?)

	forwarder.delete(e2)
	e2 = EventGenerator.new(true)
	forwarder << e2
	assert(forwarder.controlable?)

	assert([e1,e2].all? { |ev| ev.parent_object?(forwarder, EventStructure::Signal) })
	forwarder.call(nil)
	assert([e1,e2].all? { |ev| ev.happened? })
    end

    def setup_aggregation(mock)
	e1, e2, m1, m2, m3 = 5.enum_for(:times).map { EventGenerator.new(true) }
	e1.on e2
	m1.on m2
	m2.on m3

        (e1 & e2 & m2).on { mock.and }
        (e2 | m1).on { mock.or }
        ((e2 & m1) | m2).on { mock.and_or }

        ((e2 | m1) & m2).on { mock.or_and }
        [e1, e2, m1, m2, m3]
    end

    def test_aggregator
        FlexMock.use do |mock|
            e1, e2, m1, *_ = setup_aggregation(mock)
	    e2.on m1
            mock.should_receive(:or).once
            mock.should_receive(:and).once
            mock.should_receive(:and_or).once
            mock.should_receive(:or_and).once
            e1.call(nil)
        end

        FlexMock.use do |mock|
            e1, *_ = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).never
            mock.should_receive(:or_and).never
            e1.call(nil)
        end

        FlexMock.use do |mock|
            _, _, m1 = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).once
            mock.should_receive(:or_and).once
            m1.call(nil)
        end
    end

    def test_or
	a, b, c = 3.enum_for(:times).map { EventGenerator.new(true) }

        or_event = (a | b)
        or_event.on c
        assert( a.enum_for(:each_causal_link).find { |ev| ev == or_event } )
        assert( or_event.enum_for(:each_causal_link).find { |ev| ev == c } )
	a.call(nil)
	assert(c.happened?)
    end

    def test_ensure
	setup = lambda do |mock|
	    e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)
	    e1.ensure e2
	    e1.on { mock.e1 }
	    e2.on { mock.e2 }
	    [e1, e2]
	end
	FlexMock.use do |mock|
	    e1, e2 = setup[mock]
	    mock.should_receive(:e2).ordered.once
	    mock.should_receive(:e1).ordered.once
	    e1.call(nil)
	end
	FlexMock.use do |mock|
	    e1, e2 = setup[mock]
	    mock.should_receive(:e1).never
	    mock.should_receive(:e2).once
	    e2.call(nil)
	end
	FlexMock.use do |mock|
	    e1, e2 = setup[mock]
	    mock.should_receive(:e2).ordered.once
	    mock.should_receive(:e1).ordered.once
	    e2.call(nil)
	    e1.call(nil)
	end
    end

    def test_until
	e1, e2, e3, e4 = 4.enum_for(:times).map { EventGenerator.new(true) }
	e1.on(e2)
	e2.on(e3)
	e3.until(e2).on(e4)

	e1.call(nil)
	assert( e3.happened? )
	assert( !e4.happened? )

	assert_raise(NoMethodError) { e3.until(e2).this_method_does_not_exist }
	assert_raise(NoMethodError) { e3.until(e2).emit_on(e1) }
    end

    def test_event_creation
	# Test for validation of the return value of #event
	generator = Class.new(EventGenerator) do
	    def new(context); [Propagation.propagation_id, context] end
	end.new(true)
	assert_raises(TypeError) { generator.call(nil) }

	generator = Class.new(EventGenerator) do
	    def new(context); 
		event_klass = Struct.new :propagation_id, :context, :generator
		event_klass.new(Propagation.propagation_id, context, self)
	    end
	end.new(true)
	assert_nothing_raised { generator.call(nil) }
    end

    def test_context_propagation
	e1, e2 = (1..2).map { EventGenerator.new(true) }
	e1.on e2
	
	FlexMock.use do |mock|
	    e1.on { |event| mock.e1(event.context) }
	    e2.on { |event| mock.e2(event.context) }

	    mock.should_receive(:e1).with(mock).once
	    mock.should_receive(:e2).with(mock).once
	    e1.call(mock)
	end
    end

    def test_preconditions
	e1 = EventGenerator.new(true)
	e1.precondition("context must be non-nil") do |generator, context|
	    context
	end

	assert_raises(EventPreconditionFailed) { e1.call(nil) }
	assert_nothing_raised { e1.call(true) }
    end

    def test_cancel
	e1 = Class.new(EventGenerator) do
	    def calling(context)
		cancel("testing cancel method")
	    end
	end.new(true)
	assert_raises(EventCanceled) { e1.call(nil) }
    end

    def test_related_events
	e1, e2 = (1..2).map { EventGenerator.new(true) }

	assert_equal([].to_value_set, e1.related_events)
	e1.on e2
	assert_equal([e2].to_value_set, e1.related_events)
	assert_equal([e1].to_value_set, e2.related_events)
    end

    def test_related_tasks
	e1, e2 = (1..2).map { EventGenerator.new(true) }
	t1 = Task.new

	assert_equal([].to_value_set, e1.related_tasks)
	e1.on t1.event(:start)
	assert_equal([t1].to_value_set, e1.related_tasks)
    end

    def test_command_set
	FlexMock.use do |mock|
	    ev = EventGenerator.new
	    assert(!ev.controlable?)

	    ev.command = lambda { mock.first }
	    mock.should_receive(:first).once.ordered
	    assert(ev.controlable?)
	    ev.call(nil)

	    ev.command = lambda { mock.second }
	    mock.should_receive(:second).once.ordered
	    assert(ev.controlable?)
	    ev.call(nil)

	    ev.command = nil
	    assert(!ev.controlable?)
	end
    end
end

