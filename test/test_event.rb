$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/test/tasks/simple_task'

require 'roby'
class TC_Event < Test::Unit::TestCase
    include Roby::Test
    def setup
        super
        Roby.app.filter_backtraces = false
    end

    def test_no_plan
        event = EventGenerator.new { }
        assert(!event.executable?)
        assert_raises(Roby::EventNotExecutable) { event.emit }
        assert_raises(Roby::EventNotExecutable) { event.call }

        plan.add(event)
        assert(event.executable?)
    end

    def test_controlable_events
	event = EventGenerator.new(true)
	assert(event.controlable?)

	# Check command & emission behavior for controlable events
	FlexMock.use do |mock|
	    plan.add(event = EventGenerator.new { |context| mock.call_handler(context); event.emit(*context) })
	    event.on { |event| mock.event_handler(event.context) }

	    assert(event.controlable?)
	    mock.should_receive(:call_handler).once.with([42])
	    mock.should_receive(:event_handler).once.with([42])
	    event.call(42)
	end
    end

    def test_contingent_events
	# Check emission behavior for non-controlable events
	FlexMock.use do |mock|
	    event = EventGenerator.new
	    plan.add(event)
	    event.on { |event| mock.event(event.context) }
	    mock.should_receive(:event).once.with([42])
	    event.emit(42)
	end
    end

    def test_explicit_executable_flag
	plan.add(event = EventGenerator.new(true))
        assert(event.executable?)
	event.executable = false
	assert_raises(EventNotExecutable) { event.call(nil) }
	assert_raises(EventNotExecutable) { event.emit(nil) }

	event.executable = true
	assert_nothing_raised { event.call(nil) }
	assert_nothing_raised { event.emit(nil) }

	plan.add(other = EventGenerator.new(true))
	other.executable = false
	event.signals other
	assert_raises(EventNotExecutable) { event.call(nil) }

	event.remove_signal(other)
	assert_nothing_raised { event.emit(nil) }
	event.forward_to other
	assert_raises(EventNotExecutable) { event.call(nil) }

	event.remove_forwarding(other)
	assert_nothing_raised { event.emit(nil) }
	event.on { other.emit(nil) }
	assert_original_error(EventNotExecutable, EventHandlerError) { event.call(nil) }
    end

    def test_emit_failed_raises
	plan.add(event = EventGenerator.new)
	assert_original_error(NilClass, EmissionFailed) { event.emit_failed }
	assert_original_error(NilClass, EmissionFailed) { event.emit_failed("test") }

	klass = Class.new(EmissionFailed)
	assert_raises(klass) { event.emit_failed(klass) }
	assert_raises(klass) { event.emit_failed(klass, "test") }
	begin; event.emit_failed(klass, "test")
	rescue klass => e
	    assert( e.message =~ /: test$/ )
	end

	exception = klass.new(nil, event)
	assert_raises(klass) { event.emit_failed(exception, "test") }
	begin; event.emit_failed(exception, "test")
	rescue klass => e
	    assert_equal(event, e.failed_generator)
	    assert( e.message =~ /: test$/ )
	end
    end

    def test_emit_failed_removes_pending
	event = EventGenerator.new { }
	plan.add(event)
	event.call
	assert(event.pending?)
	assert_raises(EmissionFailed) { event.emit_failed }
	assert(!event.pending?)
    end

    def test_propagation_id
	e1, e2, e3 = (1..3).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }
	e1.signals e2
	e1.emit(nil)
	assert_equal(e1.last.propagation_id, e2.last.propagation_id)

	e2.emit(nil)
	assert(e1.last.propagation_id < e2.last.propagation_id)

	e3.emit(nil)
	assert(e1.last.propagation_id < e3.last.propagation_id)
	assert(e2.last.propagation_id < e3.last.propagation_id)
    end


    def test_signals_without_delay
	e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)
	plan.add([e1, e2])

        e1.signals e2

        assert( e1.child_object?( e2, EventStructure::Signal ))
        assert( e2.parent_object?( e1, EventStructure::Signal ))

        e1.call(nil)
        assert(e2.happened?)
    end

    def test_forward_to_without_delay
	e1, e2 = EventGenerator.new, Roby::EventGenerator.new
	plan.add([e1, e2])

        e1.forward_to e2

        assert( e1.child_object?( e2, EventStructure::Forwarding ))
        assert( e2.parent_object?( e1, EventStructure::Forwarding ))

        e1.emit(nil)
        assert(e2.happened?)
    end

    # b.emit_on(a) is replaced by a.forward_to(b)
    def test_deprecated_emit_on
	e1, e2 = EventGenerator.new, Roby::EventGenerator.new
	plan.add([e1, e2])

        deprecated_feature do
            e2.emit_on e1
        end

        assert( e1.child_object?( e2, EventStructure::Forwarding ))
        assert( e2.parent_object?( e1, EventStructure::Forwarding ))

        e1.emit(nil)
        assert(e2.happened?)
    end

    # forward has been renamed into #forward_to
    def test_deprecated_forward
	e1, e2 = EventGenerator.new, Roby::EventGenerator.new
	plan.add([e1, e2])

        deprecated_feature do
            e1.forward e2
        end

        assert( e1.child_object?( e2, EventStructure::Forwarding ))
        assert( e2.parent_object?( e1, EventStructure::Forwarding ))

        e1.emit(nil)
        assert(e2.happened?)
    end

    def test_deprecated_on
	e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)
	plan.add([e1, e2])

        deprecated_feature do
            e1.on e2
        end

        assert( e1.child_object?( e2, EventStructure::Signal ))
        assert( e2.parent_object?( e1, EventStructure::Signal ))

        e1.call(nil)
        assert(e2.happened?)
    end
 
    def test_handlers
	e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)
	plan.add([e1, e2])
	e1.on { e2.call(nil) }

	FlexMock.use do |mock|
	    e1.on { mock.e1 }
	    e2.on { mock.e2 }
	    e1.on { mock.happened?(e1.happened?) }
	    mock.should_receive(:happened?).once.with(true)
	    mock.should_receive(:e1).once.ordered
	    mock.should_receive(:e2).once.ordered
	    e1.call(nil)
	end
    end

    def common_test_source_setup(forwarding)
	src    = EventGenerator.new(true)
	e      = EventGenerator.new(true)
        target = EventGenerator.new(true)
        plan.add([src, e, target])
        src.signals e
        yield(e, target)
        src.call
        if forwarding
            assert_equal([e.last], target.last.sources.to_a)
        else
            assert_equal([], target.last.sources.to_a)
        end
    end
    def test_forward_source
        common_test_source_setup(true) { |e, target| e.forward_to target }
    end
    def test_forward_in_handler_source
        common_test_source_setup(true) { |e, target| e.on { target.emit } }
    end
    def test_forward_in_command_source
        common_test_source_setup(false) { |e, target| e.command = lambda { |_| target.emit; e.emit } }
    end
    def test_signal_source
        common_test_source_setup(false) { |e, target| e.signals target }
    end
    def test_signal_in_handler_source
        common_test_source_setup(false) { |e, target| e.on { target.call } }
    end
    def test_signal_in_command_source
        common_test_source_setup(false) { |e, target| e.command = lambda { |_| target.call; e.emit } }
    end

    def test_simple_signal_handler_ordering
	e1, e2, e3 = (1..3).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }
	e1.signals(e2)
	e1.on { e2.remove_signal(e3) }
	e2.signals(e3)

	e1.call(nil)
	assert( e2.happened? )
	assert( !e3.happened? )
    end

    def test_event_hooks
        FlexMock.use do |mock|
	    hooks = [:calling, :called, :fired]
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
	    plan.add(generator)
            
	    hooks.each do |name|
		mock.should_receive(name).once.with(generator).ordered
	    end
            generator.call(nil)
        end
    end

    def test_postpone
	wait_for = EventGenerator.new(true)
	event = EventGenerator.new(true)
	plan.add([wait_for, event])
	event.singleton_class.class_eval do
	    define_method(:calling) do |context|
		super if defined? super
		unless wait_for.happened?
		    postpone(wait_for, "bla") {}
		end
	    end
	end

	event.call(nil)
	assert(! event.happened?)
	assert(! event.pending?)
	assert(wait_for.child_object?(event, EventStructure::Signal))
	wait_for.call(nil)
	assert(event.happened?)

	# Test propagation when the block given to postpone signals the event
	# we are waiting for
        FlexMock.use do |mock|
	    wait_for = EventGenerator.new(true)
	    event = EventGenerator.new(true)
	    plan.add([wait_for, event])
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
	plan.add([a, b])
	assert_raises(EventNotControlable) { a.signals b }
	assert_nothing_raised { a.forward_to b }

	a, b = EventGenerator.new(true), EventGenerator.new(true)
	plan.add([a, b])
	a.signals b
	def b.controlable?; false end

	assert_raise(EmissionFailed) { a.call(nil) }
    end

    def test_and_generator
	and_event = AndGenerator.new
	FlexMock.use do |mock|
	    and_event.on { mock.called }
	    mock.should_receive(:called).once

	    events = 5.enum_for(:times).map { EventGenerator.new(true) }
	    plan.add(events)
	    events.each { |ev| and_event << ev }

	    events.each do |ev| 
		ev.call(nil)
		if ev != events[-1]
		    assert(!and_event.happened?)
		end
	    end

	    assert(and_event.happened?)

	    # Call the events again. The and generator should not emit.
	    # This is checked by the flexmock object
	    events.each do |ev| 
		ev.call(nil)
	    end
	end
	
	# Check the behavior of the & operator
	e1, e2, e3, e4 = (1..4).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }
	and_event = e1 & e2
	and_and = and_event & e3
	assert_equal([e1, e2].to_set, and_event.waiting.to_set)
	and_and = e4 & and_event
	assert_equal([e1, e2].to_set, and_event.waiting.to_set)

	# Check dynamic behaviour
	a, b, c, d = (1..4).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }
        and1 = a & b
	and2 = and1 & c
        and2.signals d
        assert_equal([and1], a.enum_for(:each_signal).to_a)
        assert_equal([and1], b.enum_for(:each_signal).to_a)
        assert_equal([and2], and1.enum_for(:each_signal).to_a)
        assert_equal([and2], c.enum_for(:each_signal).to_a)
        assert_equal([d], and2.enum_for(:each_signal).to_a)

	a.call(nil)
	assert_equal([b], and1.waiting)
	assert(! and1.happened?)

	c.call(nil)
	assert_equal([and1], and2.waiting)
	assert(! and2.happened?)
	
	b.call(nil)
	assert(and1.happened?)
	assert(and2.happened?)
	assert_equal([], and1.waiting)
	assert_equal([], and2.waiting)

	assert(d.happened?)
    end

    def test_and_empty
	plan.add(and_event = AndGenerator.new)

	assert(and_event.empty?)
	and_event << EventGenerator.new(true)
	assert(!and_event.empty?)

    end

    def test_and_unreachability
	a, b = (1..2).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }

	# Test unreachability
	## it is unreachable once emitted, but if_unreachable(true) blocks
	## must no be called
	and_event = (a & b)
	FlexMock.use do |mock|
	    and_event.if_unreachable(true) do
		mock.unreachable
	    end
	    mock.should_receive(:unreachable).never
	    a.call
	    assert( !and_event.unreachable? )
	    b.call
	    assert( !and_event.unreachable? )
	end

	## must be unreachable once one of the nonemitted source events are
	and_event = (a & b)
	a.call
	a.unreachable!
	assert(!and_event.unreachable?)
	b.unreachable!
	assert(and_event.unreachable?)
    end

    def test_and_reset
	a, b = (1..2).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }
	and_event = (a & b)
	a.emit(nil)

	and_event.reset
	b.emit(nil)
	assert(!and_event.happened?)
	a.emit(nil)
	assert(and_event.happened?)

	and_event.reset
	a.emit(nil)
	b.emit(nil)
	assert_equal(2, and_event.history.size)

	and_event.on { and_event.reset }
	and_event.reset
	a.emit(nil)
	b.emit(nil)
	assert_equal(3, and_event.history.size)
	a.emit(nil)
	b.emit(nil)
	assert_equal(4, and_event.history.size)
    end

    def setup_aggregation(mock)
	e1, e2, m1, m2, m3 = 5.enum_for(:times).map { EventGenerator.new(true) }
	plan.add([e1, e2, m1, m2, m3])
	e1.signals e2
	m1.signals m2
	m2.signals m3

        (e1 & e2 & m2).on { mock.and }
        (e2 | m1).on { mock.or }
        ((e2 & m1) | m2).on { mock.and_or }

        ((e2 | m1) & m2).on { mock.or_and }
        [e1, e2, m1, m2, m3]
    end

    def test_aggregator
        FlexMock.use do |mock|
            e1, e2, m1, *_ = setup_aggregation(mock)
	    e2.signals m1
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

    def test_or_generator
	a, b, c = (1..3).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }

	or_event = OrGenerator.new
	assert(or_event.empty?)
	or_event << a << b
	assert(!or_event.empty?)

        or_event = (a | b)
        or_event.signals c
        assert( a.enum_for(:each_causal_link).find { |ev| ev == or_event } )
        assert( or_event.enum_for(:each_causal_link).find { |ev| ev == c } )
	a.call(nil)
	assert(c.happened?)
	assert( or_event.happened? )
    end

    def test_or_emission
	plan.add(or_event = OrGenerator.new)
	events = (1..4).map { EventGenerator.new(true) }.
	    each { |e| or_event << e }

	FlexMock.use do |mock|
	    or_event.on { mock.called }
	    mock.should_receive(:called).once
	    events.each_with_index do |ev, i|
		ev.call(nil)
		assert(ev.happened?)
	    end
	end
    end

    def test_or_reset
	plan.add(or_event = OrGenerator.new)
	events = (1..4).map { EventGenerator.new(true) }.
	    each { |e| or_event << e }

	FlexMock.use do |mock|
	    events.each_with_index do |ev, i|
		ev.call
		assert_equal(i + 1, or_event.history.size)
		or_event.reset
	    end
	end
    end

    def test_or_unreachability
	# Test unreachability properties
	a, b = (1..3).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }
        or_event = (a | b)
	
	## must be unreachable once emitted, but if_unreachable(true) blocks
	## must not be called
	FlexMock.use do |mock|
	    or_event.if_unreachable(true) do
		mock.unreachable
	    end
	    mock.should_receive(:unreachable).never

	    assert( !or_event.unreachable? )
	    a.call
	    assert( !or_event.unreachable? )
	end

	## must be unreachable if all its source events are
	or_event = (a | b)
	a.unreachable!
	assert(!or_event.unreachable?)
	b.unreachable!
	assert(or_event.unreachable?)
    end


    def test_until
	source, sink, filter, limit = 4.enum_for(:times).map { EventGenerator.new(true) }
	plan.add [source, sink, filter, limit]

	source.signals(filter)
	filter.until(limit).signals(sink)

	FlexMock.use do |mock|
	    sink.on { mock.passed }
	    mock.should_receive(:passed).once

	    source.call(nil)
	    limit.call(nil)
	    source.call(nil)
	end
    end

    def test_event_creation
	# Test for validation of the return value of #event
	generator = Class.new(EventGenerator) do
	    def new(context); [] end
	end.new(true)
	plan.add(generator)

	assert_raises(EmissionFailed) { generator.emit(nil) }

	generator = Class.new(EventGenerator) do
	    def new(context); 
		event_klass = Struct.new :propagation_id, :context, :generator, :sources
		event_klass.new(plan.engine.propagation_id, context, self)
	    end
	end.new(true)
	plan.add(generator)
	assert_nothing_raised { generator.call(nil) }
    end

    def test_context_propagation
	FlexMock.use do |mock|
	    e1 = EventGenerator.new { |context| mock.e1_cmd(context); e1.emit(*context) }
	    e2 = EventGenerator.new { |context| mock.e2_cmd(context); e2.emit(*context) }
	    e1.signals e2
	    e1.on { |event| mock.e1(event.context) }
	    e2.on { |event| mock.e2(event.context) }
	    plan.add([e1, e2])

	    mock.should_receive(:e1_cmd).with([mock]).once
	    mock.should_receive(:e2_cmd).with([mock]).once
	    mock.should_receive(:e1).with([mock]).once
	    mock.should_receive(:e2).with([mock]).once
	    e1.call(mock)
	end

	FlexMock.use do |mock|
	    pass_through = EventGenerator.new(true)
	    e2 = EventGenerator.new { |context| mock.e2_cmd(context); e2.emit(*context) }
	    pass_through.signals e2
	    pass_through.on { |event| mock.e1(event.context) }
	    e2.on { |event| mock.e2(event.context) }
	    plan.add([pass_through, e2])

	    mock.should_receive(:e2_cmd).with([mock]).once
	    mock.should_receive(:e1).with([mock]).once
	    mock.should_receive(:e2).with([mock]).once
	    pass_through.call(mock)
	end

	FlexMock.use do |mock|
	    e1 = EventGenerator.new { |context| mock.e1_cmd(context); e1.emit(*context) }
	    e2 = EventGenerator.new { |context| mock.e2_cmd(context); e2.emit(*context) }
	    e1.signals e2
	    e1.on { |event| mock.e1(event.context) }
	    e2.on { |event| mock.e2(event.context) }
	    plan.add([e1, e2])

	    mock.should_receive(:e1_cmd).with(nil).once
	    mock.should_receive(:e2_cmd).with(nil).once
	    mock.should_receive(:e1).with(nil).once
	    mock.should_receive(:e2).with(nil).once
	    e1.call
	end
    end

    def test_preconditions
	plan.add(e1 = EventGenerator.new(true))
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
	plan.add(e1)
	assert_raises(EventCanceled) { e1.call(nil) }
    end

    def test_related_events
	e1, e2 = (1..2).map { EventGenerator.new(true) }.
	    each { |ev| plan.add(ev) }

	assert_equal([].to_value_set, e1.related_events)
	e1.signals e2
	assert_equal([e2].to_value_set, e1.related_events)
	assert_equal([e1].to_value_set, e2.related_events)
    end

    def test_related_tasks
	e1, e2 = (1..2).map { EventGenerator.new(true) }.
	    each { |ev| plan.add(ev) }
	t1 = SimpleTask.new

	assert_equal([].to_value_set, e1.related_tasks)
	e1.signals t1.event(:start)
	assert_equal([t1].to_value_set, e1.related_tasks)
    end

    def test_command
	FlexMock.use do |mock|
	    ev = EventGenerator.new do |context|
		ev.emit(*context)
		mock.called(*context)
	    end
	    plan.add(ev)

	    mock.should_receive(:called).with(42).once
	    ev.call(42)

	    assert(ev.happened?)
	    assert_equal(1, ev.history.size, ev.history)
	    assert(!ev.pending?)
	end
    end

    def test_set_command
	FlexMock.use do |mock|
	    ev = EventGenerator.new
	    plan.add(ev)
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

    def test_once
	plan.add(ev = EventGenerator.new(true))
	FlexMock.use do |mock|
	    ev.once { mock.called_once }
	    mock.should_receive(:called_once).once

	    ev.call
	    ev.call
	end
    end

    def test_signal_once
	ev1, ev2 = EventGenerator.new(true), EventGenerator.new(true)
	plan.add([ev1, ev2])

	FlexMock.use do |mock|
	    ev1.signals_once(ev2)
	    ev2.on { mock.called }

	    mock.should_receive(:called).once

	    ev1.call
	    ev1.call
	end
    end

    def test_forward_once
	ev1, ev2 = EventGenerator.new(true), EventGenerator.new(true)
	plan.add([ev1, ev2])

	FlexMock.use do |mock|
	    ev1.forward_to_once(ev2)
	    ev2.on { mock.called }

	    mock.should_receive(:called).once

	    ev1.call
	    ev1.call
	end
    end

    def test_filter
	ev1, ev_block, ev_value, ev_nil = (1..4).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }

	FlexMock.use do |mock|
	    ev1.filter { |v| mock.filtering(v); v*2 }.signals ev_block
	    ev_block.on { |ev| mock.block_filter(ev.context) }

	    ev1.filter(42).signals ev_value
	    ev_value.on { |ev| mock.value_filter(ev.context) }

	    ev1.filter.signals ev_nil
	    ev_nil.on { |ev| mock.nil_filter(ev.context) }

	    mock.should_receive(:filtering).with(21).once
	    mock.should_receive(:block_filter).with([ 42 ]).once
	    mock.should_receive(:value_filter).with([42]).once
	    mock.should_receive(:nil_filter).with(nil).once
	    ev1.call(21)
	end
    end

    def test_gather_events
	e1, e2 = (1..2).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }

	collection = []

	EventGenerator.gather_events(collection, [e2])
	e1.call
	assert_equal([], collection.map { |ev| ev.generator })
	e2.emit(nil)
	assert_equal([e2], collection.map { |ev| ev.generator })

	collection.clear
	EventGenerator.gather_events(collection, [e1])
	e1.call
	assert_equal([e1], collection.map { |ev| ev.generator })
	e2.emit(nil)
	assert_equal([e1, e2], collection.map { |ev| ev.generator })

	# Check that the triggering events are cleared when the events are
	# removed from the plan
	collection.clear
	plan.remove_object(e1)
        assert(!EventGenerator.event_gathering.has_key?(e1))

	EventGenerator.remove_event_gathering(collection)
    end

    def test_achieve_with
	slave  = EventGenerator.new
	master = EventGenerator.new do
	    master.achieve_with slave
	end
	plan.add([master, slave])

	master.call
	assert(!master.happened?)
	slave.emit
	assert(master.happened?)

	# Test what happens if the slave fails
	slave  = EventGenerator.new
	master = EventGenerator.new do
	    master.achieve_with slave
	end
	plan.add([master, slave])

	master.call
	assert(!master.happened?)
	assert_raises(UnreachableEvent) { plan.remove_object(slave) }

	# Now test the filtering case (when a block is given)
	slave  = EventGenerator.new
	master = EventGenerator.new do
	    master.achieve_with(slave) { [21, 42] }
	end
	plan.add([master, slave])

	master.call
	slave.emit
	assert(master.happened?)
	assert_equal(nil,  slave.history[0].context)
	assert_equal([[21, 42]], master.history[0].context)
    end

    def test_if_unreachable
	FlexMock.use do |mock|
	    plan.add(ev = EventGenerator.new(true))
	    ev.if_unreachable(false) { mock.called }
	    ev.if_unreachable(true) { mock.canceled_called }
	    ev.call

	    mock.should_receive(:called).once
	    mock.should_receive(:canceled_called).never
	    engine.garbage_collect
	end
    end

    def test_when_unreachable
        plan.add(ev = EventGenerator.new(true))
        ev.when_unreachable.on { |ev| mock.unreachable_fired }
        ev.call
        engine.garbage_collect
        assert(ev.happened?)
    end

    def test_or_if_unreachable
	plan.add(e1 = EventGenerator.new(true))
	plan.add(e2 = EventGenerator.new(true))
	a = e1 | e2
	FlexMock.use do |mock|
	    a.if_unreachable(false) { mock.called }
	    mock.should_receive(:called).never
	    plan.remove_object(e1)
	end

	FlexMock.use do |mock|
	    a.if_unreachable(false) { mock.called }
	    mock.should_receive(:called).once
	    plan.remove_object(e2)
	end
    end

    def test_and_if_unreachable
	FlexMock.use do |mock|
	    plan.add(e1 = EventGenerator.new(true))
	    plan.add(e2 = EventGenerator.new(true))
	    a = e1 & e2

	    a.if_unreachable(false) { mock.called }
	    e1.call

	    mock.should_receive(:called).once
	    plan.remove_object(e2)
	end

	FlexMock.use do |mock|
	    plan.add(e1 = EventGenerator.new(true))
	    plan.add(e2 = EventGenerator.new(true))
	    a = e1 & e2

	    a.if_unreachable(false) { mock.called }
	    e1.call

	    mock.should_receive(:called).never
	    plan.remove_object(e1)
	end
    end

    def test_dup
	plan.add(e = EventGenerator.new(true))

	e.call
	new = e.dup
	e.call
	assert_equal(2, e.history.size)
	assert_equal(1, new.history.size)
    end

    def test_event_after
	FlexMock.use(Time) do |time_proxy|
	    current_time = Time.now + 5
	    time_proxy.should_receive(:now).and_return { current_time }

	    plan.add(e = EventGenerator.new(true))
	    e.call
	    current_time += 0.5
	    plan.add(delayed = e.last.after(1))
	    delayed.poll
	    assert(!delayed.happened?)
	    current_time += 0.5
	    delayed.poll
	    assert(delayed.happened?)
	end
    end
end
