require 'roby/test/self'

class TC_Event < Minitest::Test
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

    def test_call_without_propagation_raises
        plan.add(ev = Roby::EventGenerator.new { |_| raise ArgumentError })
        assert_raises(Roby::CommandFailed) { ev.call }
    end

    def test_emit_without_propagation_raises
        plan.add(ev = Roby::EventGenerator.new)
        ev.on do |_|
            raise ArgumentError
        end
        assert_raises(Roby::EventHandlerError) { ev.emit }
    end

    def test_error_in_command_before_emission_causes_an_emission_failure
        mock = flexmock
        mock.should_receive(:event_handler_called).never

        ev = Roby::EventGenerator.new do |context|
            raise ArgumentError
            ev.emit
        end
        ev.on { mock.event_handler_called }

        ev_mock = flexmock(ev)
        ev_mock.should_receive(:emit_failed).once.
            and_return do |error, *_|
                plan.engine.add_error(error)
            end

        plan.add(ev)
        assert_raises(Roby::CommandFailed) { ev.call }
        assert(!ev.emitted?)
    end

    def test_error_in_command_after_emission_does_not_causes_an_emission_failure
        mock = flexmock
        mock.should_receive(:event_handler_called).once

        ev = Roby::EventGenerator.new do |context|
            ev.emit
            raise ArgumentError
        end
        ev.on { mock.event_handler_called }

        ev_mock = flexmock(ev)
        ev_mock.should_receive(:emit_failed).never.
            and_return do |error, *_|
                plan.engine.add_error(error)
            end

        plan.add(ev)
        assert_raises(Roby::CommandFailed) { ev.call }
        assert(ev.emitted?)
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

        plan.add(event = EventGenerator.new(true))
        event.executable = false
        assert_raises(EventNotExecutable) { event.emit(nil) }

	event.executable = true
	event.call(nil)
	event.emit(nil)

	plan.add(other = EventGenerator.new(true))
	other.executable = false
	event.signals other
        assert_event_fails(other, EventNotExecutable) { event.call(nil) }

	plan.add(event = EventGenerator.new(true))
	plan.add(other = EventGenerator.new(true))
	other.executable = false
	event.remove_signal(other)
	event.emit(nil)
	event.forward_to other
        assert_event_fails(other, EventNotExecutable) { event.call(nil) }

	plan.add(event = EventGenerator.new(true))
	event.emit(nil)
	event.on { |ev| other.emit(nil) }
	assert_original_error(EventNotExecutable, EventHandlerError) { event.call(nil) }
    end

    def assert_event_fails(ev, error_type)
        begin
            yield
        rescue error_type
        end
        assert(ev.unreachable?, "#{ev} was expected to be marked as unreachable, but is not")
        assert_kind_of(error_type, ev.unreachability_reason)
    end

    def assert_emission_failed(ev, error_type)
        assert_event_fails(ev, EmissionFailed) do
            assert_raises(error_type) do
                yield
            end
        end
        assert_kind_of(error_type, ev.unreachability_reason.error, "unreachability reason set to #{ev.unreachability_reason.error}, expected an instance of #{error_type}")
    end

    def test_emit_failed_raises
	plan.add(event = EventGenerator.new)
	assert_original_error(NilClass, EmissionFailed) { event.emit_failed }
	plan.add(event = EventGenerator.new)
	assert_original_error(NilClass, EmissionFailed) { event.emit_failed("test") }

	klass = Class.new(EmissionFailed)
	plan.add(event = EventGenerator.new)
	assert_event_fails(event, klass) { event.emit_failed(klass) }
	plan.add(event = EventGenerator.new)
	assert_event_fails(event, klass) { event.emit_failed(klass, "test") }
        inhibit_fatal_messages do
            begin; event.emit_failed(klass, "test")
            rescue klass => e
                assert( e.message =~ /: test$/ )
            end
        end

	plan.add(event = EventGenerator.new)
	exception = klass.new(nil, event)
	assert_event_fails(event, klass) { event.emit_failed(exception, "test") }
        assert_equal(event, event.unreachability_reason.failed_generator)
    end

    def test_pending_includes_queued_events
        plan.add_permanent_event(e = EventGenerator.new { })
        execution_engine.process_events_synchronous do
            e.emit
            assert e.pending?
            assert !e.emitted?
        end
        assert !e.pending?
        assert e.emitted?
    end

    def test_command_failure_does_not_remove_pending
        e = EventGenerator.new do
            raise ArgumentError
        end
        plan.add(e)
        flexmock(e).should_receive(:emit_failed).once.and_return do |*args|
            assert(e.pending?)
            flexmock_call_original(e, :emit_failed, *args)
        end
        inhibit_fatal_messages do
            assert_raises(Roby::CommandFailed) { e.call }
        end
        assert(!e.pending?)
    end

    def test_emit_failed_removes_pending
	event = EventGenerator.new { }
	plan.add(event)
	event.call
	assert(event.pending?)
	assert_event_fails(event, EmissionFailed) { event.emit_failed }
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
        assert(e2.emitted?)
    end

    def test_forward_to_without_delay
	e1, e2 = EventGenerator.new, Roby::EventGenerator.new
	plan.add([e1, e2])

        e1.forward_to e2

        assert( e1.child_object?( e2, EventStructure::Forwarding ))
        assert( e2.parent_object?( e1, EventStructure::Forwarding ))

        e1.emit(nil)
        assert(e2.emitted?)
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
        assert(e2.emitted?)
    end

    def test_handlers
	e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)
	plan.add([e1, e2])
	e1.on { |ev| e2.call(nil) }

	FlexMock.use do |mock|
	    e1.on { |ev| mock.e1 }
	    e2.on { |ev| mock.e2 }
	    e1.on { |ev| mock.emitted?(e1.emitted?) }
	    mock.should_receive(:emitted?).once.with(true)
	    mock.should_receive(:e1).once.ordered
	    mock.should_receive(:e2).once.ordered
	    e1.call(nil)
	end
    end

    def common_test_source_setup(keep_source)
	src    = EventGenerator.new(true)
	e      = EventGenerator.new(true)
        target = EventGenerator.new(true)
        plan.add([src, e, target])
        src.signals e
        yield(e, target)
        src.call
        if keep_source
            assert_equal([e.last], target.last.sources.to_a)
        else
            assert_equal([], target.last.sources.to_a)
        end
    end
    def test_forward_source
        common_test_source_setup(true) { |e, target| e.forward_to target }
    end
    def test_forward_in_handler_source
        common_test_source_setup(true) { |e, target| e.on { |ev| target.emit } }
    end
    def test_forward_in_command_source
        common_test_source_setup(false) { |e, target| e.command = lambda { |_| target.emit; e.emit } }
    end
    def test_signal_source
        common_test_source_setup(true) { |e, target| e.signals target }
    end
    def test_signal_in_handler_source
        common_test_source_setup(true) { |e, target| e.on { |ev| target.call } }
    end
    def test_signal_in_command_source
        common_test_source_setup(false) { |e, target| e.command = lambda { |_| target.call; e.emit } }
    end

    def test_simple_signal_handler_ordering
	e1, e2, e3 = (1..3).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }
	e1.signals(e2)
	e1.on { |ev| e2.remove_signal(e3) }
	e2.signals(e3)

	e1.call(nil)
	assert( e2.emitted? )
	assert( !e3.emitted? )
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


    def test_can_signal
	a, b = EventGenerator.new(true), EventGenerator.new
	plan.add([a, b])
	assert_raises(EventNotControlable) { a.signals b }
	a.forward_to b

	a, b = EventGenerator.new(true), EventGenerator.new(true)
	plan.add([a, b])
	a.signals b
	def b.controlable?; false end

        assert_raises(EmissionFailed) { a.call(nil) }
    end


    def test_if_unreachable_unconditional
        mock = flexmock
        mock.should_receive(:unreachable_1).once.ordered
        mock.should_receive(:unreachable_2).once.ordered

        plan.add(ev = EventGenerator.new)
        ev.if_unreachable(cancel_at_emission: false) { mock.unreachable_1 }
        plan.remove_free_event(ev)

        plan.add(ev = EventGenerator.new)
        ev.if_unreachable(cancel_at_emission: false) { mock.unreachable_2 }
        ev.emit
        plan.remove_free_event(ev)
    end

    def test_if_unreachable_in_transaction_is_ignored_on_discard
        mock = flexmock
        mock.should_receive(:unreachable).never

        plan.in_transaction do |trsc|
            trsc.add(ev = EventGenerator.new)
            ev.if_unreachable { mock.unreachable }
            trsc.remove_free_event(ev)
        end
    end

    def test_if_unreachable_if_not_signalled
        mock = flexmock
        mock.should_receive(:unreachable_1).once.ordered
        mock.should_receive(:unreachable_2).never.ordered

        plan.add(ev = EventGenerator.new)
        ev.if_unreachable(cancel_at_emission: true) { mock.unreachable_1 }
        plan.remove_free_event(ev)

        plan.add(ev = EventGenerator.new)
        mock = flexmock
        ev.if_unreachable(cancel_at_emission: true) { mock.unreachable_2 }
        ev.emit
        plan.remove_free_event(ev)
    end

    def test_and_unreachability
	a, b = (1..2).map { EventGenerator.new(true) }.
	    each { |e| plan.add(e) }

	# Test unreachability
	## it is unreachable once emitted, but if_unreachable(true) blocks
	## must no be called
	and_event = (a & b)
	FlexMock.use do |mock|
	    and_event.if_unreachable(cancel_at_emission: true) do
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
	assert(!and_event.emitted?)
	a.emit(nil)
	assert(and_event.emitted?)

	and_event.reset
	a.emit(nil)
	b.emit(nil)
	assert_equal(2, and_event.history.size)

	and_event.on { |ev| and_event.reset }
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

        (e1 & e2 & m2).on { |ev| mock.and }
        (e2 | m1).on { |ev| mock.or }
        ((e2 & m1) | m2).on { |ev| mock.and_or }

        ((e2 | m1) & m2).on { |ev| mock.or_and }
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

    def test_until
	source, sink, filter, limit = 4.enum_for(:times).map { EventGenerator.new(true) }
        [source, sink, filter, limit].each do |ev|
            plan.add_permanent_event ev
        end

	source.signals(filter)
	filter.until(limit).signals(sink)

        mock = flexmock
        sink.on { |ev| mock.passed }
        mock.should_receive(:passed).once

        source.call(nil)
        limit.call(nil)
        source.call(nil)
    end

    FakeEvent = Struct.new :propagation_id, :context, :generator, :sources, :time
    class FakeEvent
        def add_sources(*args)
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
	    def new(context)
                FakeEvent.new(plan.execution_engine.propagation_id, context, self, Time.now)
	    end
	end.new(true)
	plan.add(generator)
	generator.call(nil)
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
        plan.add(e1 = EventGenerator.new(true))
	e1.call(true)
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

	assert_equal([].to_set, e1.related_events)
	e1.signals e2
	assert_equal([e2].to_set, e1.related_events)
	assert_equal([e1].to_set, e2.related_events)
    end

    def test_related_tasks
	e1, e2 = (1..2).map { EventGenerator.new(true) }.
	    each { |ev| plan.add(ev) }
	t1 = Tasks::Simple.new

	assert_equal([].to_set, e1.related_tasks)
	e1.signals t1.event(:start)
	assert_equal([t1].to_set, e1.related_tasks)
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

	    assert(ev.emitted?)
	    assert_equal(1, ev.history.size, ev.history)
	    assert(!ev.pending?)
	end
    end

    def test_set_command
	FlexMock.use do |mock|
	    ev = EventGenerator.new
	    plan.add(ev)
	    assert(!ev.controlable?)

	    ev.command = lambda { |_| mock.first }
	    mock.should_receive(:first).once.ordered
	    assert(ev.controlable?)
	    ev.call(nil)

	    ev.command = lambda { |_| mock.second }
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
	    ev.once { |_| mock.called_once }
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
	    ev2.on { |ev| mock.called }

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
	    ev2.on { |ev| mock.called }

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

    def test_achieve_with
	slave  = EventGenerator.new
	master = EventGenerator.new do
	    master.achieve_with slave
	end
	plan.add([master, slave])

	master.call
	assert(!master.emitted?)
	slave.emit
	assert(master.emitted?)

	# Test what happens if the slave fails
	slave  = EventGenerator.new
	master = EventGenerator.new do
	    master.achieve_with slave
	end
	plan.add([master, slave])

	master.call
	assert(!master.emitted?)
        assert_event_fails(master, EmissionFailed) do
            plan.remove_free_event(slave)
        end

	# Now test the filtering case (when a block is given)
	slave  = EventGenerator.new
	master = EventGenerator.new do
	    master.achieve_with(slave) { [21, 42] }
	end
	plan.add([master, slave])

	master.call
	slave.emit
	assert(master.emitted?)
	assert_equal(nil,  slave.history[0].context)
	assert_equal([[21, 42]], master.history[0].context)
    end

    def test_when_unreachable_block
	FlexMock.use do |mock|
	    plan.add(ev = EventGenerator.new(true))
            ev.when_unreachable(false) { mock.called }
            ev.when_unreachable(true) { mock.canceled_called }
	    ev.call

	    mock.should_receive(:called).once
	    mock.should_receive(:canceled_called).never
	    execution_engine.garbage_collect
	end
    end

    def test_when_unreachable_event_not_cancelled_at_emission
        mock = flexmock
        mock.should_receive(:unreachable_fired).once

        plan.add(ev = EventGenerator.new(true))
        ev.when_unreachable(false).on { |ev| mock.unreachable_fired }
        ev.call
        plan.remove_free_event(ev)
    end

    def test_when_unreachable_event_cancelled_at_emission
        mock = flexmock
        mock.should_receive(:unreachable_fired).never

        plan.add(ev = EventGenerator.new(true))
        ev.when_unreachable(true).on { |ev| mock.unreachable_fired }
        ev.call
        plan.remove_free_event(ev)
    end

    def test_or_if_unreachable
	plan.add(e1 = EventGenerator.new(true))
	plan.add(e2 = EventGenerator.new(true))
	a = e1 | e2
        e1.unreachable!
        assert(!a.unreachable?)

        e2.unreachable!
        assert(a.unreachable?)
    end

    def test_and_on_removal
	FlexMock.use do |mock|
	    plan.add(e1 = EventGenerator.new(true))
	    plan.add(e2 = EventGenerator.new(true))
	    a = e1 & e2
	    e1.call
            e2.remove_child_object(a, Roby::EventStructure::Signal)
            e2.unreachable!
            assert(!a.unreachable?, "#{a} has become unreachable when e2 did, but e2 is not a source from a anymore")
	end
    end

    def test_and_if_unreachable
        plan.add(e1 = EventGenerator.new(true))
        plan.add(e2 = EventGenerator.new(true))
        a = e1 & e2
        e1.call
        e2.unreachable!
        assert(a.unreachable?)

        plan.add(e1 = EventGenerator.new(true))
        plan.add(e2 = EventGenerator.new(true))
        a = e1 & e2
        e2.call
        e1.unreachable!
        assert(a.unreachable?)
    end

    def test_dup
	plan.add(e = EventGenerator.new(true))
	plan.register_event(new = e.dup)

	e.call
	assert_equal(1, e.history.size)
        assert(e.emitted?)
	assert_equal(0, new.history.size)
	assert(!new.emitted?)

        plan.register_event(new = e.dup)
	assert_equal(1, e.history.size)
        assert(e.emitted?)
	assert_equal(1, new.history.size)
	assert(new.emitted?)

        new.call
	assert_equal(1, e.history.size)
        assert(e.emitted?)
	assert_equal(2, new.history.size)
	assert(new.emitted?)
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
	    assert(!delayed.emitted?)
	    current_time += 0.5
	    delayed.poll
	    assert(delayed.emitted?)
	end
    end

    def test_exception_in_once_handler
        plan.add(ev = EventGenerator.new(true))
        FlexMock.use do |mock|
            ev.on { |ev| mock.called_other_handler }
            ev.once { |_| raise ArgumentError }
            ev.once { |_| mock.called_other_once_handler }

            mock.should_receive(:called_other_handler).once
            mock.should_receive(:called_other_once_handler).once
            assert_raises(EventHandlerError) { ev.call }
        end
    end

    def test_exception_in_handler
        plan.add(ev = EventGenerator.new(true))
        FlexMock.use do |mock|
            ev.on { |ev| mock.called_other_handler }
            ev.on { |ev| raise ArgumentError }
            ev.once { |ev| mock.called_other_once_handler }

            mock.should_receive(:called_other_handler).once
            mock.should_receive(:called_other_once_handler).once
            assert_raises(EventHandlerError) { ev.call }
        end
    end

    def test_cannot_be_pending_if_not_executable
        model = Class.new(EventGenerator) do
            def executable?
                pending?
            end
        end

        plan.add(ev = model.new(true))
        assert_raises(Roby::EventNotExecutable) { ev.call }
        plan.add(ev = model.new(true))
        assert_raises(Roby::EventNotExecutable) { ev.emit }
    end

    def test_forward_source_is_event_source
        GC.disable
        plan.add(target = Roby::EventGenerator.new(true))
        plan.add(source = Roby::EventGenerator.new(true))

        source.forward_to target
        source.call
        assert_equal [source.last], target.last.sources.to_a

    ensure
        GC.enable
    end

    def test_command_source_is_event_source
        GC.disable
        plan.add(target = Roby::EventGenerator.new(true))
        plan.add(source = Roby::EventGenerator.new(true))

        source.signals target
        source.call
        assert_equal [source.last], target.last.sources.to_a

    ensure
        GC.enable
    end

    def test_pending_command_source_is_event_source
        target = Roby::EventGenerator.new do
        end
        plan.add(target)
        plan.add(source = Roby::EventGenerator.new(true))

        source.signals target
        source.call
        assert(target.pending?)

        target.emit
        assert_equal [source.last], target.last.sources.to_a
    end

    def test_plain_all_and_root_sources
        plan.add(root = Roby::EventGenerator.new(true))
        plan.add(i1 = Roby::EventGenerator.new)
        plan.add(i2 = Roby::EventGenerator.new)
        plan.add(target = Roby::EventGenerator.new)
        root.forward_to i1
        root.forward_to i2
        i1.forward_to target
        i2.forward_to target

        root.emit
        event = target.last
        assert_equal [i1.last, i2.last].to_set, event.sources.to_set
        assert_equal [root.last, i1.last, i2.last].to_set, event.all_sources.to_set
        assert_equal [root.last].to_set, event.root_sources.to_set
    end

    def test_adding_a_handler_from_within_a_handler_does_not_call_the_new_handler
        plan.add(event = Roby::EventGenerator.new)
        called = false
        event.on do |context|
            event.on { |context| called = true }
        end
        event.emit
        assert !called
    end

    def test_calling_unreachable_outside_propagation_raises_the_unreachability_reason
        plan.add(event = Roby::EventGenerator.new)
        exception = Class.new(Exception).new
        assert_raises(exception.class) { event.unreachable!(exception) }
    end
end

describe Roby::EventGenerator do
    include Roby::SelfTest

    describe "#achieve_asynchronously" do
        attr_reader :ev, :main_thread, :recorder

        before do
            plan.add_permanent_event(@ev = Roby::EventGenerator.new(true))
            @main_thread = Thread.current
            @recorder = flexmock
        end
        it "calls the provided block in a separate thread" do
            recorder = flexmock
            recorder.should_receive(:called).once.with(proc { |thread| thread != main_thread })
            ev.achieve_asynchronously { recorder.called(Thread.current) }
            process_events
        end
        it "calls emit_failed if the block raises" do
            flexmock(ev).should_receive(:emit_failed).once.
                with(proc { |e| e.kind_of?(ArgumentError) && Thread.current == main_thread })
            ev.achieve_asynchronously { raise ArgumentError }
            process_events
        end
        it "accepts a promise as argument" do
            recorder, result = flexmock, flexmock
            recorder.should_receive(:call).with(Thread.current, result)
            promise = execution_engine.
                promise { result }.
                on_success { |result| recorder.call(Thread.current, result) }

            ev.achieve_asynchronously(promise)
            inhibit_fatal_messages { process_events }
        end
        it "emits the event on success if the emit_on_success option is true" do
            recorder.should_receive(:call).ordered
            flexmock(ev).should_receive(:emit).once.with(proc { |*args| Thread.current == main_thread }).ordered
            ev.achieve_asynchronously(emit_on_success: true) { recorder.call }
            execution_engine.join_all_waiting_work
        end
        it "should not emit the event automatically if the emit_on_success option is false" do
            ev.achieve_asynchronously(emit_on_success: false) { true }
            process_events
            assert !ev.emitted?
        end

        it "calls emit_failed if the emission fails" do
            flexmock(ev).should_receive(:emit).once.and_raise(ArgumentError)
            flexmock(ev).should_receive(:emit_failed).once.with(proc { |e| Thread.current == main_thread })
            promise = execution_engine.promise { }
            ev.achieve_asynchronously(promise)
            process_events
        end

        it "calls emit_failed if the callback raises" do
            flexmock(ev).should_receive(:emit_failed).once.
                with(proc { |e| e.kind_of?(ArgumentError) && Thread.current == main_thread })
            promise = execution_engine.promise { }.
                on_success { raise ArgumentError }
            ev.achieve_asynchronously(promise)
            process_events
        end
    end
end
