# frozen_string_literal: true

require "roby/test/self"

class TC_EventGenerator < Minitest::Test # rubocop:disable Metrics/ClassLength
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
            execute { event.call(42) }
        end
    end

    def test_contingent_events
        # Check emission behavior for non-controlable events
        FlexMock.use do |mock|
            event = EventGenerator.new
            plan.add(event)
            event.on { |event| mock.event(event.context) }
            mock.should_receive(:event).once.with([42])
            execute { event.emit(42) }
        end
    end

    def test_pending_includes_queued_events
        plan.add(e = EventGenerator.new {})
        execute do
            e.emit
            assert e.pending?
            refute e.emitted?
        end
        refute e.pending?
        assert e.emitted?
    end

    def test_propagation_id
        e1, e2, e3 = (1..3).map { EventGenerator.new(true) }
            .each { |e| plan.add(e) }
        e1.signals e2
        execute { e1.emit(nil) }
        assert_equal(e1.last.propagation_id, e2.last.propagation_id)

        execute { e2.emit(nil) }
        assert(e1.last.propagation_id < e2.last.propagation_id)

        execute { e3.emit(nil) }
        assert(e1.last.propagation_id < e3.last.propagation_id)
        assert(e2.last.propagation_id < e3.last.propagation_id)
    end

    def test_signals_without_delay
        e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)
        plan.add([e1, e2])

        e1.signals e2

        assert(e1.child_object?(e2, EventStructure::Signal))
        assert(e2.parent_object?(e1, EventStructure::Signal))

        expect_execution { e1.call(nil) }
            .to { emit e2 }
    end

    def test_forward_to_without_delay
        e1, e2 = EventGenerator.new, Roby::EventGenerator.new
        plan.add([e1, e2])

        e1.forward_to e2

        assert(e1.child_object?(e2, EventStructure::Forwarding))
        assert(e2.parent_object?(e1, EventStructure::Forwarding))

        execute { e1.emit(nil) }
        assert(e2.emitted?)
    end

    # forward has been renamed into #forward_to
    def test_deprecated_forward
        e1, e2 = EventGenerator.new, Roby::EventGenerator.new
        plan.add([e1, e2])

        deprecated_feature do
            e1.forward e2
        end

        assert(e1.child_object?(e2, EventStructure::Forwarding))
        assert(e2.parent_object?(e1, EventStructure::Forwarding))

        e1.emit(nil)
        assert(e2.emitted?)
    end

    def common_test_source_setup(keep_source)
        src    = EventGenerator.new(true)
        e      = EventGenerator.new(true)
        target = EventGenerator.new(true)
        plan.add([src, e, target])
        src.signals e
        yield(e, target)
        execute { src.call }
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
        common_test_source_setup(false) do |e, target|
            e.command = ->(_) { target.emit; e.emit }
        end
    end

    def test_signal_source
        common_test_source_setup(true) { |e, target| e.signals target }
    end

    def test_signal_in_handler_source
        common_test_source_setup(true) { |e, target| e.on { |ev| target.call } }
    end

    def test_signal_in_command_source
        common_test_source_setup(false) do |e, target|
            e.command = ->(_) { target.call; e.emit }
        end
    end

    def test_simple_signal_handler_ordering
        e1, e2, e3 = (1..3).map { EventGenerator.new(true) }
            .each { |e| plan.add(e) }
        e1.signals(e2)
        e1.on { |ev| e2.remove_signal(e3) }
        e2.signals(e3)

        execute { e1.call(nil) }
        assert(e2.emitted?)
        assert(!e3.emitted?)
    end

    def test_event_hooks
        FlexMock.use do |mock|
            hooks = %i[calling called fired]
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
            execute { generator.call(nil) }
        end
    end

    def test_if_unreachable_unconditional
        mock = flexmock
        mock.should_receive(:unreachable1).once.ordered
        mock.should_receive(:unreachable2).once.ordered

        plan.add(ev = EventGenerator.new)
        ev.if_unreachable(cancel_at_emission: false) { mock.unreachable1 }
        execute { plan.remove_free_event(ev) }

        plan.add(ev = EventGenerator.new)
        ev.if_unreachable(cancel_at_emission: false) { mock.unreachable2 }
        execute { ev.emit }
        execute { plan.remove_free_event(ev) }
    end

    def test_if_unreachable_in_transaction_is_ignored_on_discard
        mock = flexmock
        mock.should_receive(:unreachable).never

        plan.in_transaction do |trsc|
            trsc.add(ev = EventGenerator.new)
            ev.if_unreachable { mock.unreachable }
            execute { trsc.remove_free_event(ev) }
        end
    end

    def test_if_unreachable_if_not_signalled
        mock = flexmock
        mock.should_receive(:unreachable1).once.ordered
        mock.should_receive(:unreachable2).never.ordered

        plan.add(ev = EventGenerator.new)
        ev.if_unreachable(cancel_at_emission: true) { mock.unreachable1 }
        execute { plan.remove_free_event(ev) }

        plan.add(ev = EventGenerator.new)
        mock = flexmock
        ev.if_unreachable(cancel_at_emission: true) { mock.unreachable2 }
        execute { ev.emit }
        execute { plan.remove_free_event(ev) }
    end

    def test_and_unreachability
        a, b = (1..2).map { EventGenerator.new(true) }
            .each { |e| plan.add(e) }

        # Test unreachability
        ## it is unreachable once emitted, but if_unreachable(true) blocks
        ## must no be called
        and_event = (a & b)
        FlexMock.use do |mock|
            and_event.if_unreachable(cancel_at_emission: true) do
                mock.unreachable
            end
            mock.should_receive(:unreachable).never
            execute { a.call }
            assert(!and_event.unreachable?)
            execute { b.call }
            assert(!and_event.unreachable?)
        end

        ## must be unreachable once one of the nonemitted source events are
        and_event = (a & b)
        execute { a.call }
        execute { a.unreachable! }
        assert(!and_event.unreachable?)
        execute { b.unreachable! }
        assert(and_event.unreachable?)
    end

    def test_and_reset
        a, b = (1..2).map { EventGenerator.new(true) }
            .each { |e| plan.add(e) }
        and_event = (a & b)
        execute { a.emit(nil) }

        and_event.reset
        execute { b.emit(nil) }
        assert(!and_event.emitted?)
        execute { a.emit(nil) }
        assert(and_event.emitted?)

        and_event.reset
        execute { a.emit(nil) }
        execute { b.emit(nil) }
        assert_equal(2, and_event.history.size)

        and_event.on { |ev| and_event.reset }
        and_event.reset
        execute { a.emit(nil) }
        execute { b.emit(nil) }
        assert_equal(3, and_event.history.size)
        execute { a.emit(nil) }
        execute { b.emit(nil) }
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
            e1, e2, m1, = setup_aggregation(mock)
            e2.signals m1
            mock.should_receive(:or).once
            mock.should_receive(:and).once
            mock.should_receive(:and_or).once
            mock.should_receive(:or_and).once
            execute { e1.call(nil) }
        end

        FlexMock.use do |mock|
            e1, = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).never
            mock.should_receive(:or_and).never
            execute { e1.call(nil) }
        end

        FlexMock.use do |mock|
            _, _, m1 = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).once
            mock.should_receive(:or_and).once
            execute { m1.call(nil) }
        end
    end

    def test_until
        source, sink, filter, limit = 4.enum_for(:times).map { EventGenerator.new(true) }
        [source, sink, filter, limit].each do |ev|
            plan.add ev
        end

        source.signals(filter)
        filter.until(limit).signals(sink)

        mock = flexmock
        sink.on { |ev| mock.passed }
        mock.should_receive(:passed).once

        execute { source.call(nil) }
        execute { limit.call(nil) }
        execute { source.call(nil) }
    end

    def test_related_events
        e1, e2 = (1..2).map { EventGenerator.new(true) }
            .each { |ev| plan.add(ev) }

        assert_equal([].to_set, e1.related_events)
        e1.signals e2
        assert_equal([e2].to_set, e1.related_events)
        assert_equal([e1].to_set, e2.related_events)
    end

    def test_related_tasks
        e1, e2 = (1..2).map { EventGenerator.new(true) }
            .each { |ev| plan.add(ev) }
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
            execute { ev.call(42) }

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

            ev.command = ->(_) { mock.first }
            mock.should_receive(:first).once.ordered
            assert(ev.controlable?)
            execute { ev.call(nil) }

            ev.command = ->(_) { mock.second }
            mock.should_receive(:second).once.ordered
            assert(ev.controlable?)
            execute { ev.call(nil) }

            ev.command = nil
            assert(!ev.controlable?)
        end
    end

    def test_once
        plan.add(ev = EventGenerator.new(true))
        FlexMock.use do |mock|
            ev.once { |_| mock.called_once }
            mock.should_receive(:called_once).once

            execute { ev.call }
            execute { ev.call }
        end
    end

    def test_signal_once
        ev1, ev2 = EventGenerator.new(true), EventGenerator.new(true)
        plan.add([ev1, ev2])

        FlexMock.use do |mock|
            ev1.signals_once(ev2)
            ev2.on { |ev| mock.called }

            mock.should_receive(:called).once

            execute { ev1.call }
            execute { ev1.call }
        end
    end

    def test_forward_once
        ev1, ev2 = EventGenerator.new(true), EventGenerator.new(true)
        plan.add([ev1, ev2])

        FlexMock.use do |mock|
            ev1.forward_to_once(ev2)
            ev2.on { |ev| mock.called }

            mock.should_receive(:called).once

            execute { ev1.call }
            execute { ev1.call }
        end
    end

    def test_when_unreachable_block
        FlexMock.use do |mock|
            plan.add(ev = EventGenerator.new(true))
            ev.when_unreachable(false) { mock.called }
            ev.when_unreachable(true) { mock.canceled_called }
            execute { ev.call }

            mock.should_receive(:called).once
            mock.should_receive(:canceled_called).never
            execute { execution_engine.garbage_collect }
        end
    end

    def test_when_unreachable_event_not_cancelled_at_emission
        mock = flexmock
        mock.should_receive(:unreachable_fired).once

        plan.add(ev = EventGenerator.new(true))
        ev.when_unreachable(false).on { |ev| mock.unreachable_fired }
        execute { ev.call }
        execute { plan.remove_free_event(ev) }
    end

    def test_when_unreachable_event_cancelled_at_emission
        mock = flexmock
        mock.should_receive(:unreachable_fired).never

        plan.add(ev = EventGenerator.new(true))
        ev.when_unreachable(true).on { |ev| mock.unreachable_fired }
        execute { ev.call }
        execute { plan.remove_free_event(ev) }
    end

    def test_or_if_unreachable
        plan.add(e1 = EventGenerator.new(true))
        plan.add(e2 = EventGenerator.new(true))
        a = e1 | e2
        execute { e1.unreachable! }
        assert(!a.unreachable?)

        execute { e2.unreachable! }
        assert(a.unreachable?)
    end

    def test_and_on_removal
        FlexMock.use do |mock|
            plan.add(e1 = EventGenerator.new(true))
            plan.add(e2 = EventGenerator.new(true))
            a = e1 & e2
            execute { e1.call }
            execute { e2.remove_child_object(a, Roby::EventStructure::Signal) }
            execute { e2.unreachable! }
            assert(!a.unreachable?, "#{a} has become unreachable when e2 did, but e2 is not a source from a anymore")
        end
    end

    def test_and_if_unreachable
        plan.add(e1 = EventGenerator.new(true))
        plan.add(e2 = EventGenerator.new(true))
        a = e1 & e2
        execute { e1.call }
        execute { e2.unreachable! }
        assert(a.unreachable?)

        plan.add(e1 = EventGenerator.new(true))
        plan.add(e2 = EventGenerator.new(true))
        a = e1 & e2
        execute { e2.call }
        execute { e1.unreachable! }
        assert(a.unreachable?)
    end

    def test_dup
        plan.add(e = EventGenerator.new(true))
        plan.register_event(new = e.dup)

        execute { e.call }
        assert_equal(1, e.history.size)
        assert(e.emitted?)
        assert_equal(0, new.history.size)
        assert(!new.emitted?)

        plan.register_event(new = e.dup)
        assert_equal(1, e.history.size)
        assert(e.emitted?)
        assert_equal(1, new.history.size)
        assert(new.emitted?)

        execute { new.call }
        assert_equal(1, e.history.size)
        assert(e.emitted?)
        assert_equal(2, new.history.size)
        assert(new.emitted?)
    end

    def test_dup_separates_the_sources
        plan.add(e = EventGenerator.new(true))

        plan.register_event(source = EventGenerator.new(true))
        plan.register_event(new = e.dup)
        source.forward_to(new)
        execute { source.emit }

        plan.register_event(new = e.dup)
        source.forward_to(new)
        execute { source.emit }
        assert_equal 1, new.history.size
        ev = new.history[0]
        assert_equal 1, ev.all_sources.size
    end

    def test_event_after
        FlexMock.use(Time) do |time_proxy|
            current_time = Time.now + 5
            time_proxy.should_receive(:now).and_return { current_time }

            plan.add(e = EventGenerator.new(true))
            execute { e.call }
            current_time += 0.5
            plan.add(delayed = e.last.after(1))
            execute { delayed.poll }
            assert(!delayed.emitted?)
            current_time += 0.5
            execute { delayed.poll }
            assert(delayed.emitted?)
        end
    end

    def test_forward_source_is_event_source
        GC.disable
        plan.add(target = Roby::EventGenerator.new(true))
        plan.add(source = Roby::EventGenerator.new(true))

        source.forward_to target
        execute { source.call }
        assert_equal [source.last], target.last.sources.to_a
    ensure
        GC.enable
    end

    def test_command_source_is_event_source
        GC.disable
        plan.add(target = Roby::EventGenerator.new(true))
        plan.add(source = Roby::EventGenerator.new(true))

        source.signals target
        execute { source.call }
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
        execute { source.call }
        assert(target.pending?)

        execute { target.emit }
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

        execute { root.emit }
        event = target.last
        assert_equal [i1.last, i2.last].to_set, event.sources.to_set
        assert_equal [root.last, i1.last, i2.last].to_set, event.all_sources.to_set
        assert_equal [root.last].to_set, event.root_sources.to_set
    end
end

module Roby
    describe EventGenerator do
        describe "context propagation" do
            attr_reader :mock

            before do
                @mock = flexmock
            end

            describe "within the default pass-thru command" do
                it "passes the context as-is" do
                    plan.add(generator = EventGenerator.new(true))
                    generator.on { |event| mock.called(event.context) }
                    mock.should_receive(:called).with([1, 2]).once
                    execute { generator.call(1, 2) }
                end

                it "passes the context as-is" do
                    plan.add(generator = EventGenerator.new(true))
                    generator.on { |event| mock.called(event.context) }
                    mock.should_receive(:called).with([]).once
                    execute { generator.call }
                end
            end

            describe "passed to commands" do
                describe "from #call" do
                    it "passes an empty array to its command when given no context" do
                        plan.add(generator = EventGenerator.new { |context| mock.called(context) })
                        mock.should_receive(:called).with([]).once
                        execute { generator.call }
                    end
                    it "passes an array with a single value if given one" do
                        plan.add(generator = EventGenerator.new { |context| mock.called(context) })
                        mock.should_receive(:called).with([1]).once
                        execute { generator.call(1) }
                    end
                    it "splats multiple values" do
                        plan.add(generator = EventGenerator.new { |context| mock.called(context) })
                        mock.should_receive(:called).with([1, 2]).once
                        execute { generator.call(1, 2) }
                    end
                end

                describe "from signals" do
                    attr_reader :source, :generator

                    before do
                        plan.add(@source = EventGenerator.new)
                        @generator = EventGenerator.new { |context| mock.called(context) }
                        source.signals generator
                    end
                    it "passes an empty array to its command when given no context" do
                        mock.should_receive(:called).with([]).once
                        execute { source.emit }
                    end
                    it "passes an array with a single value to its command" do
                        mock.should_receive(:called).with([1]).once
                        execute { source.emit(1) }
                    end
                    it "splats multiple values" do
                        mock.should_receive(:called).with([1, 2]).once
                        execute { source.emit(1, 2) }
                    end
                    it "concatenates the context of multiple sources" do
                        empty_source = EventGenerator.new
                        other_source = EventGenerator.new
                        empty_source.signals generator
                        other_source.signals generator
                        mock.should_receive(:called).once
                            .with(->(context) { context.to_set == Set[1, 2, 3, 4] })

                        execute do
                            empty_source.emit
                            source.emit(1, 2)
                            other_source.emit(3, 4)
                        end
                    end
                end
            end

            describe "passed to emission" do
                attr_reader :generator

                before do
                    plan.add(@generator = EventGenerator.new)
                end
                describe "from #emit" do
                    it "sets the events context to an empty array if given no context" do
                        generator.on { |event| mock.called(event.context) }
                        mock.should_receive(:called).with([]).once
                        execute { generator.emit }
                    end
                    it "aggregates values in an array" do
                        generator.on { |event| mock.called(event.context) }
                        mock.should_receive(:called).with([1, 2]).once
                        execute { generator.emit(1, 2) }
                    end
                end

                describe "from forwarding" do
                    attr_reader :source

                    before do
                        plan.add(@source = EventGenerator.new)
                        source.forward_to generator
                    end
                    it "sets the events context to an empty array if given no context" do
                        generator.on { |event| mock.called(event.context) }
                        mock.should_receive(:called).with([]).once
                        execute { source.emit }
                    end
                    it "propagates multiple values in an array" do
                        generator.on { |event| mock.called(event.context) }
                        mock.should_receive(:called).with([1, 2]).once
                        execute { source.emit(1, 2) }
                    end
                    it "concatenates the context of multiple sources" do
                        empty_source = EventGenerator.new
                        other_source = EventGenerator.new
                        generator.on { |event| mock.called(event.context) }
                        empty_source.forward_to generator
                        other_source.forward_to generator
                        mock.should_receive(:called).once
                            .with(->(context) { context.to_set == Set[1, 2, 3, 4] })

                        execute do
                            empty_source.emit
                            source.emit(1, 2)
                            other_source.emit(3, 4)
                        end
                    end
                end
            end
        end

        describe "#achieve_asynchronously" do
            attr_reader :ev, :main_thread, :recorder

            before do
                plan.add(@ev = Roby::EventGenerator.new(true))
                @main_thread = Thread.current
                @recorder = flexmock
            end
            it "calls the provided block in a separate thread" do
                recorder = flexmock
                recorder.should_receive(:called).once.with(proc { |thread| thread != main_thread })
                ev.achieve_asynchronously { recorder.called(Thread.current) }
                expect_execution.to_run
            end
            it "calls emit_failed if the block raises" do
                flexmock(ev).should_receive(:emit_failed).once
                    .with(proc { |e| e.kind_of?(ArgumentError) && Thread.current == main_thread })
                ev.achieve_asynchronously { raise ArgumentError }
                expect_execution.to_run
            end
            it "accepts a promise as argument" do
                recorder, result = flexmock, flexmock
                recorder.should_receive(:call).with(Thread.current, result)
                promise = execution_engine
                    .promise { result }
                    .on_success { |result| recorder.call(Thread.current, result) }

                ev.achieve_asynchronously(promise)
                expect_execution.to_run
            end
            it "emits the event on success if the emit_on_success option is true" do
                recorder.should_receive(:call).ordered
                flexmock(ev).should_receive(:emit).once.with(proc { |*args| Thread.current == main_thread }).ordered
                ev.achieve_asynchronously(emit_on_success: true) { recorder.call }
                execution_engine.join_all_waiting_work
            end
            it "passes the context argument to the emission" do
                context = [flexmock]
                ev.achieve_asynchronously(emit_on_success: true, context: context) {}
                emitted = expect_execution.to { emit ev }
                assert_equal context, emitted.context
            end
            it "should not emit the event automatically if the emit_on_success option is false" do
                ev.achieve_asynchronously(emit_on_success: false) { true }
                expect_execution.to { not_emit ev }
            end

            it "calls emit_failed if the emission fails" do
                flexmock(ev).should_receive(:emit).once.and_raise(ArgumentError)
                flexmock(ev).should_receive(:emit_failed).once.with(proc { |e| Thread.current == main_thread })
                promise = execution_engine.promise {}
                ev.achieve_asynchronously(promise)
                expect_execution.to_run
            end

            it "calls emit_failed if the callback raises" do
                flexmock(ev).should_receive(:emit_failed).once
                    .with(proc { |e| e.kind_of?(ArgumentError) && Thread.current == main_thread })
                promise = execution_engine.promise {}
                    .on_success { raise ArgumentError }
                ev.achieve_asynchronously(promise)
                expect_execution.to_run
            end

            it "emits if the callback raises and on_failure is :emit" do
                promise = execution_engine.promise {}
                    .on_success { raise ArgumentError }
                ev.achieve_asynchronously(promise, on_failure: :emit)
                expect_execution.to { emit ev }
            end

            it "passes the context argument to the on_failure emission" do
                promise = execution_engine.promise {}
                    .on_success { raise ArgumentError }
                context = [flexmock]
                ev.achieve_asynchronously(promise, on_failure: :emit, context: context)
                emitted = expect_execution.to { emit ev }
                assert_equal context, emitted.context
            end

            it "does nothing if on_failure is :nothing" do
                promise = execution_engine.promise {}
                    .on_success { raise ArgumentError }
                ev.achieve_asynchronously(promise, on_failure: :nothing)
                recorder = flexmock
                recorder.should_receive(:called).once
                promise.on_error { recorder.called }
                expect_execution.to_run
            end

            describe "null promises" do
                it "emits right away" do
                    expect_execution { ev.achieve_asynchronously(Roby::Promise.null) }
                        .to { emit ev }
                end
                it "passes the context argument to the emission" do
                    context = [flexmock]
                    emitted = expect_execution { ev.achieve_asynchronously(Roby::Promise.null, context: context) }
                        .to { emit ev }
                    assert_equal context, emitted.context
                end
                it "does nothing if emit_on_success if false" do
                    expect_execution { ev.achieve_asynchronously(Roby::Promise.null, emit_on_success: false) }
                        .to { not_emit ev }
                end
            end
        end

        describe "#check_call_validity" do
            attr_reader :generator

            before do
                plan.add(@generator = EventGenerator.new(true))
                flexmock(execution_engine)
            end

            it "does not check if the event is executable" do
                # It is checked after the #calling hooks are called, as #calling
                # can be used to verify executability
                generator.executable = false
                assert_nil generator.check_call_validity
            end

            it "reports if the event has been finalized" do
                execute { plan.remove_free_event(generator) }
                assert_kind_of EventNotExecutable, generator.check_call_validity
            end

            it "reports if the event is in a non-executable plan" do
                generator = EventGenerator.new
                assert_kind_of EventNotExecutable, generator.check_call_validity
            end

            it "reports if the event is not controlable" do
                plan.add(generator = EventGenerator.new)
                assert_kind_of EventNotControlable, generator.check_call_validity
            end

            it "does not report a nil unreachability reason" do
                execute { generator.unreachable! }
                error = generator.check_call_validity
                assert_kind_of UnreachableEvent, error
                assert_equal "#call called on #{generator} which has been made unreachable",
                             error.message
            end

            it "reports the unreachability reason if it is available" do
                execute { generator.unreachable!("test") }
                error = generator.check_call_validity
                assert_kind_of UnreachableEvent, error
                assert_equal "#call called on #{generator} which has been made unreachable because of test",
                             error.message
            end

            it "reports if called outside propagation context" do
                execution_engine.should_receive(:allow_propagation?).and_return(false)
                assert_kind_of PhaseMismatch, generator.check_call_validity
            end

            it "reports if called outside the engine thread" do
                execution_engine.should_receive(:inside_control?).and_return(false)
                assert_kind_of ThreadMismatch, generator.check_call_validity
            end
        end

        describe "#call_without_propagation" do
            attr_reader :generator, :command_hook

            before do
                @command_hook = flexmock
                command_hook.should_receive(:call).by_default
                plan.add(@generator = Roby::EventGenerator.new { command_hook.call })
                flexmock(generator)
                flexmock(execution_engine)
            end

            it "returns nil if #check_call_validity returns an error, and registers the error" do
                error = Class.new(LocalizedError).new(generator)
                generator.should_receive(:check_call_validity)
                    .and_return(error).once
                generator.should_receive(:calling).never

                expect_execution { generator.call_without_propagation([]) }
                    .to { have_error_matching LocalizedError.match.with_origin(generator) }
            end

            it "reports an error if #executable? is false after #calling" do
                generator.executable = true
                flexmock(generator).should_receive(:calling)
                    .and_return { generator.executable = false }

                command_hook.should_receive(:call).never
                expect_execution { generator.call_without_propagation([]) }
                    .to { have_error_matching EventNotExecutable.match.with_origin(generator) }
            end

            it "lets the #calling hook set the executable flag to true" do
                generator.executable = false
                flexmock(generator).should_receive(:calling).and_return { generator.executable = true }
                execute { generator.call_without_propagation([]) }
            end

            it "sets #command_emitted? if the command called #emit" do
                command_hook.should_receive(:call)
                    .and_return do
                        refute generator.command_emitted?
                        generator.emit
                        assert generator.command_emitted?
                    end
                execute { generator.call_without_propagation([]) }
            end

            it "sets pending after the executable check has been done" do
                test_context = self
                generator.define_singleton_method :executable? do
                    test_context.refute pending?
                    false
                end
                expect_execution { generator.call_without_propagation([]) }
                    .to { have_error_matching EventNotExecutable.match.with_origin(generator) }
            end

            describe "the command raises before the emission" do
                it "does not itself remove pending" do
                    command_hook.should_receive(:call).and_raise(RuntimeError)
                    generator.should_receive(:emit_failed).once.and_return do |*args|
                        assert generator.pending?
                        flexmock_invoke_original(generator, :emit_failed, *args)
                    end
                    expect_execution { generator.call }
                        .to { have_error_matching CommandFailed }
                    refute generator.pending?
                end

                it "reports a emission failure with a CommandFailed exception if the error was not a LocalizedError" do
                    error = Class.new(RuntimeError)
                    command_hook.should_receive(:call).and_raise(error)
                    expect_execution { generator.call_without_propagation([]) }
                        .to { have_error_matching CommandFailed.match.with_origin(generator).with_original_exception(error) }
                end

                it "reports a emission failure with the raised LocalizedError" do
                    error = Class.new(LocalizedError).new(generator)
                    command_hook.should_receive(:call).and_raise(error)
                    expect_execution { generator.call_without_propagation([]) }
                        .to { have_error_matching error.class.match.with_origin(generator) }
                end
            end

            describe "the command raises after the emission" do
                it "registers a CommandFailed error directly - without emit_failed" do
                    error = Class.new(RuntimeError)
                    command_hook.should_receive(:call)
                        .and_return { generator.emit; raise error }
                    generator.should_receive(:emit_failed).never
                    expect_execution { generator.call_without_propagation([]) }
                        .to { have_error_matching CommandFailed }
                end

                it "reports a emission failure with the raised LocalizedError without emit_failed" do
                    error = Class.new(LocalizedError).new(generator)
                    command_hook.should_receive(:call)
                        .and_return { generator.emit; raise error }
                    generator.should_receive(:emit_failed).never
                    expect_execution { generator.call_without_propagation([]) }
                        .to { have_error_matching error.class }
                end
            end
        end

        describe "#check_emission_validity" do
            attr_reader :generator

            before do
                plan.add(@generator = Roby::EventGenerator.new(true))
                flexmock(execution_engine)
            end

            it "checks if the event is executable" do
                generator = EventGenerator.new
                assert_kind_of EventNotExecutable, generator.check_emission_validity
            end

            it "does not report a nil unreachability reason" do
                execute(garbage_collect: false) { generator.unreachable! }
                error = generator.check_emission_validity
                assert_kind_of UnreachableEvent, error
                assert_equal "#emit called on #{generator} which has been made unreachable",
                             error.message
            end

            it "reports the unreachability reason if it is available" do
                execute(garbage_collect: false) { generator.unreachable!("test") }
                error = generator.check_emission_validity
                assert_kind_of UnreachableEvent, error
                assert_equal "#emit called on #{generator} which has been made unreachable because of test",
                             error.message
            end

            it "reports if called outside propagation context" do
                execution_engine.should_receive(:allow_propagation?).and_return(false)
                assert_kind_of PhaseMismatch, generator.check_emission_validity
            end

            it "reports if called outside the engine thread" do
                execution_engine.should_receive(:inside_control?).and_return(false)
                assert_kind_of ThreadMismatch, generator.check_emission_validity
            end
        end

        describe "#emit_without_propagation" do
            attr_reader :generator

            before do
                plan.add(@generator = Roby::EventGenerator.new(true))
                flexmock(generator)
                flexmock(execution_engine)
            end

            it "returns nil if #check_emission_validity returns an error, and registers the error" do
                error = Class.new(LocalizedError).new(generator)
                generator.should_receive(:check_emission_validity)
                    .and_return(error).once
                generator.should_receive(:emitting).never

                ret = nil
                expect_execution { ret = generator.emit_without_propagation([]) }
                    .to { have_error_matching error.class }
                assert_nil ret
            end

            it "returns the event that has been emitted" do
                event = execute { generator.emit_without_propagation([]) }
                assert_kind_of Event, event
                assert_equal generator, event.generator
                assert_same event, generator.last
            end

            it "calls the event handlers" do
                mock = flexmock
                mock.should_receive(:called).once
                generator.on { mock.called }
                execute { generator.emit }
            end

            it "sets emitted? before calling the handlers" do
                mock = flexmock
                mock.should_receive(:called).once.with(true)
                generator.on { mock.called(generator.emitted?) }
                execute { generator.emit }
            end

            it "calls all handlers regardless of one handler raising" do
                mock = flexmock
                generator.on { mock.failed; raise }
                generator.on { mock.success }
                mock.should_receive(:failed).once.globally.ordered
                mock.should_receive(:success).once.globally.ordered
                expect_execution { generator.emit }
                    .to { have_error_matching EventHandlerError.match.with_origin(generator) }
            end

            it "propagates signals even if a handler raises" do
                generator.signals(target = EventGenerator.new { target.emit })
                generator.on { raise }
                expect_execution { generator.emit }
                    .to do
                        emit target
                        have_error_matching EventHandlerError.match.with_origin(generator)
                    end
            end

            it "propagates forwarding even if a handler raises" do
                generator.forward_to(target = EventGenerator.new)
                generator.on { raise }
                expect_execution { generator.emit }
                    .to do
                        emit target
                        have_error_matching EventHandlerError.match.with_origin(generator)
                    end
            end

            it "emits the event even if a handler raises" do
                generator.on { raise }
                expect_execution { generator.emit }
                    .to do
                        emit generator
                        have_error_matching EventHandlerError.match.with_origin(generator)
                    end
            end

            it "registers as-is a LocalizedError raised by a handler" do
                error = Class.new(LocalizedError).new(generator)
                generator.on { raise error }
                expect_execution { generator.emit }
                    .to { have_error_matching error.class.match.with_origin(generator) }
            end

            it "transforms a non-LocalizedError raised by a handler into a EventHandlerError error" do
                error = Class.new(RuntimeError).exception("test")
                generator.on { raise error }
                expect_execution { generator.emit }
                    .to { have_error_matching EventHandlerError.match.with_original_exception(error).with_origin(generator) }
            end

            it "uses #new to create the new event object" do
                generator.should_receive(:new).with(context = flexmock).once
                    .and_return(event = flexmock(propagation_id: 0, context: 1, generator: 2, sources: 3, time: 4, add_sources: nil))
                emitted_event = execute { generator.emit_without_propagation(context) }
                assert_equal event, emitted_event
            end

            it "validates that the value returned by #new is a valid event object" do
                generator.should_receive(:new).once
                    .and_return(flexmock)
                execute do
                    assert_raises(TypeError) do
                        generator.emit_without_propagation([])
                    end
                end
            end

            it "does not call handlers that are added within the handlers themselves" do
                mock = flexmock
                generator.on do
                    generator.on { mock.called }
                end
                mock.should_receive(:called).never
                execute { generator.emit_without_propagation([]) }
            end

            it "removes once handlers within the handler list" do
                generator.once {}
                execute { generator.emit_without_propagation([]) }
                assert generator.handlers.empty?
            end

            it "does not remove once handlers that have been added by the handlers themselves" do
                mock = flexmock
                generator.on do
                    generator.once { mock.called }
                end
                execute(garbage_collect: false) { generator.emit_without_propagation([]) }
                assert_equal 2, generator.handlers.size

                mock.should_receive(:called).once
                execute { generator.emit_without_propagation([]) }
            end
        end

        describe "#emit_failed" do
            attr_reader :generator

            before do
                plan.add(@generator = EventGenerator.new)
            end

            it "uses EmissionFailed as error by default" do
                expect_execution { generator.emit_failed }
                    .to { have_error_matching EmissionFailed.match.without_ruby_exception.with_origin(generator) }
            end

            it "transforms a non-localized error into a EmissionFailed error" do
                error = Class.new(RuntimeError).new
                expect_execution { generator.emit_failed(error) }
                    .to { have_error_matching EmissionFailed.match.with_original_exception(error.class).with_origin(generator) }
            end

            it "logs the exception" do
                error = Class.new(RuntimeError).new
                flexmock(execution_engine).should_receive(:log)
                    .with(:generator_emit_failed, generator, EmissionFailed.match.with_original_exception(error.class))
                    .once
                flexmock(execution_engine).should_receive(:log)
                flexmock(execution_engine).should_receive(:add_error)
                execute { generator.emit_failed(error) }
            end

            it "causes the event to become unreachable" do
                error = Class.new(RuntimeError).new
                execution_exception = expect_execution { generator.emit_failed(error) }
                    .to do
                        become_unreachable generator
                        have_error_matching EmissionFailed
                    end
                assert_equal execution_exception.exception, generator.unreachability_reason
            end

            it "resets the event's pending flag" do
                plan.add(generator = EventGenerator.new {})
                execute { generator.call }
                assert generator.pending?
                execution_exception = expect_execution { generator.emit_failed }
                    .to { have_error_matching EmissionFailed }
                refute generator.pending?
            end
        end

        describe "#achieve_with" do
            attr_reader :master, :slave

            before do
                @slave  = EventGenerator.new
                @master = EventGenerator.new do
                    master.achieve_with slave
                end
                plan.add([master, slave])
            end

            it "emits the master when the slave is emitted" do
                expect_execution { master.call }.to { not_emit master }
                expect_execution { slave.emit }.to { emit master }
            end

            it "propagates the context of the slave to emit the master" do
                context = flexmock
                execute { master.call }
                event = expect_execution { slave.emit(context) }
                    .to { emit master }
                assert_equal [context], event.context
            end

            it "optionally filters the slave's context" do
                master_context = flexmock
                slave_context  = flexmock
                master = EventGenerator.new do
                    master.achieve_with(slave) { |event| master_context if event.context == [slave_context] }
                end
                plan.add(master)
                execute { master.call }
                event = expect_execution { slave.emit(slave_context) }
                    .to { emit master }
                assert_equal [master_context], event.context
            end

            it "does not emit the master if the filte raises" do
                master = EventGenerator.new { master.achieve_with(slave) { raise } }
                plan.add(master)
                execute { master.call }
                expect_execution { slave.emit }
                    .to do
                        not_emit master
                        have_error_matching EmissionFailed.match.with_origin(master)
                    end
            end

            it "reports filter exceptions on the master" do
                error_e = Class.new(RuntimeError)
                master = EventGenerator.new do
                    master.achieve_with(slave) { raise error_e }
                end
                plan.add(master)
                execute { master.call }
                expect_execution { slave.emit }
                    .to { have_error_matching EmissionFailed.match.with_origin(master) }
            end

            it "fails the master if the slave becomes unreachable" do
                execute { master.call }
                expect_execution { slave.unreachable! }
                    .to { have_error_matching EmissionFailed.match.with_original_exception(UnreachableEvent.match.with_origin(slave)).with_origin(master) }
            end
        end

        describe "#call" do
            attr_reader :generator

            before do
                plan.add(@generator = EventGenerator.new(true))
                flexmock(generator)
                flexmock(execution_engine)
            end
            it "queues the call on the engine" do
                execution_engine.should_receive(:queue_signal)
                    .with([], generator, [context = flexmock], nil).once
                execute { generator.call(context) }
            end
            it "uses the engine's propagation sources as propagation sources" do
                source_generator = EventGenerator.new
                execution_engine.gather_propagation do
                    execution_engine.propagation_context([source_generator]) do
                        generator.call
                    end
                end
            end
            it "validates the call validity with #check_call_validity" do
                error = Class.new(RuntimeError)
                generator.should_receive(:check_call_validity).and_return(error)
                execution_engine.should_receive(:queue_signal).never
                execute do
                    assert_raises(error) { generator.call }
                end
            end
        end

        describe "#emit" do
            attr_reader :generator

            before do
                plan.add(@generator = EventGenerator.new)
                flexmock(generator)
                flexmock(execution_engine)
            end
            it "queues the emission on the engine" do
                execution_engine.should_receive(:queue_forward)
                    .with([], generator, [context = flexmock], nil).once
                execute { generator.emit(context) }
            end
            it "uses the engine's propagation sources as propagation sources" do
                source_generator = EventGenerator.new
                execution_engine.gather_propagation do
                    execution_engine.propagation_context([source_generator]) do
                        generator.emit
                    end
                end
            end
            it "validates the emission validity with #check_emit_validity" do
                error = Class.new(RuntimeError)
                generator.should_receive(:check_emission_validity).and_return(error)
                execution_engine.should_receive(:queue_forward).never
                execute do
                    assert_raises(error) do
                        generator.emit
                    end
                end
            end
        end

        describe "#forward_to" do
            attr_reader :source, :target, :context

            before do
                @source = EventGenerator.new
                @context = flexmock
                plan.add(source)
                flexmock(execution_engine)
            end
            it "queues the target emission when the source emits" do
                target = EventGenerator.new
                source.forward_to target
                execution_engine.should_receive(:queue_forward).once
                    .with([], source, [context], nil).pass_thru
                execution_engine.should_receive(:queue_forward).once
                    .with(->(sources) { sources == [source.last] }, target, [context], nil)
                    .pass_thru
                event = expect_execution { source.emit(context) }
                    .to { emit target }
                assert_equal source.last.context, event.context
            end
            it "returns true in forwarded_to?" do
                target = EventGenerator.new
                source.forward_to target
                assert source.forwarded_to?(target)
            end
            it "returns true in forwarded_to? for unrelated events" do
                target = EventGenerator.new
                refute source.forwarded_to?(target)
            end
        end

        describe "#signals" do
            attr_reader :source, :target

            before do
                @source = EventGenerator.new
                plan.add(source)
                flexmock(execution_engine)
            end
            it "establishes a signal if the target is controlable" do
                target = EventGenerator.new(true)
                source.signals target
                context = flexmock
                execution_engine.should_receive(:queue_signal).once
                    .with(->(sources) { sources == [source.last] }, target, [context], nil)
                    .pass_thru
                expect_execution { source.emit(context) }
                    .to { emit target }
            end
            it "verifies that the target event is controlable at the point of call" do
                target = EventGenerator.new
                assert_raises(EventNotControlable) do
                    source.signals target
                end
                refute source.child_object?(target, EventStructure::Signal)
            end
            it "triggers at runtime if the target event is not controlable then" do
                # This should basically be triggering the controlable? check in
                # #call_without_propagation
                target = EventGenerator.new(true)
                source.signals target
                flexmock(target).should_receive(:controlable?).and_return(false)
                expect_execution { source.emit }
                    .to { have_error_matching EventNotControlable.match.with_origin(target) }
            end
        end

        describe "#filter" do
            attr_reader :source, :mock

            before do
                @mock = flexmock
                plan.add(@source = EventGenerator.new)
            end

            describe "when given a filter block" do
                it "emits a new event after having processed the context through the block" do
                    filter = source.filter { |val| mock.filtering(val); val * 2 }
                    filter.on { |event| mock.emitted(event.context) }
                    mock.should_receive(:filtering).with(21).once
                    mock.should_receive(:emitted).with([42]).once
                    execute { source.emit(21) }
                end

                it "filters each context value separately" do
                    filter = source.filter { |val| mock.filtering(val); val * 2 }
                    filter.on { |event| mock.emitted(event.context) }
                    mock.should_receive(:filtering).with(10).once
                    mock.should_receive(:filtering).with(20).once
                    mock.should_receive(:emitted).with([20, 40]).once
                    execute { source.emit(10, 20) }
                end
            end

            describe "when given a new context" do
                it "replaces the context by the value given" do
                    filter = source.filter(10)
                    filter.on { |event| mock.emitted(event.context) }
                    mock.should_receive(:emitted).with([10]).once
                    execute { source.emit(20) }
                end
                it "splats the value when emitting" do
                    filter = source.filter(10, 30)
                    filter.on { |event| mock.emitted(event.context) }
                    mock.should_receive(:emitted).with([10, 30]).once
                    execute { source.emit(20) }
                end
                it "removes the context when given no arguments" do
                    filter = source.filter
                    filter.on { |event| mock.emitted(event.context) }
                    mock.should_receive(:emitted).with([]).once
                    execute { source.emit(20) }
                end
            end
        end

        describe "preconditions" do
            attr_reader :generator

            before do
                plan.add(@generator = EventGenerator.new(true))
            end

            it "passes the actual generator and context" do
                expected_context = flexmock
                generator.precondition do |g, context|
                    assert_equal generator, g
                    assert_equal [expected_context], context
                    true
                end
                execute { generator.call(expected_context) }
            end

            it "raises if the precondition is failed" do
                generator.precondition { false }
                expect_execution { generator.call }
                    .to do
                        not_emit generator
                        have_error_matching EventPreconditionFailed.match.with_origin(generator)
                    end
                refute generator.pending?
            end

            it "lets the call go through if the precondition is true" do
                generator.precondition { true }
                expect_execution { generator.call }
                    .to { emit generator }
            end
        end

        describe "#cancel" do
            it "raises EventCanceled and avoids emission when called within #calling" do
                generator_class = Class.new(EventGenerator) do
                    def calling(context)
                        cancel("testing cancel method")
                    end
                end
                plan.add(generator = generator_class.new(true))
                expect_execution { generator.call }
                    .to do
                        have_error_matching EventCanceled.match.with_origin(generator)
                        not_emit generator
                    end
                refute generator.pending?
            end
        end

        describe "#on" do
            attr_reader :generator

            before do
                plan.add(@generator = EventGenerator.new)
            end
            it "raises if the on_replace argument is invalid" do
                e = assert_raises(ArgumentError) do
                    generator.on(on_replace: :invalid)
                end
                assert_equal "wrong value for the :on_replace option. Expecting either :drop or :copy, got invalid", e.message
            end
            it "sets the copy-on-replace policy" do
                generator.on(on_replace: :copy) {}
                handler = generator.handlers.last
                assert handler.copy_on_replace?
            end
            it "sets the drop-on-replace policy" do
                generator.on(on_replace: :drop) {}
                handler = generator.handlers.last
                refute handler.copy_on_replace?
            end
        end

        describe "#replace_by" do
            attr_reader :generator, :new, :mock

            before do
                plan.add(@generator = EventGenerator.new)
                plan.add(@new = EventGenerator.new)
                @mock = flexmock
            end

            describe "event handlers" do
                it "ignores handlers which have the drop-on-replace policy" do
                    generator.on(on_replace: :drop) { mock.called }
                    generator.replace_by(new)
                    mock.should_receive(:called).never
                    execute { new.emit }
                end
                it "copies handlers which have the copy-on-replace policy" do
                    generator.on(on_replace: :copy) { mock.called }
                    generator.replace_by(new)
                    mock.should_receive(:called).once
                    execute { new.emit }
                end
                it "sets the copy-on-replace policy on the copied handlers" do
                    generator.on(on_replace: :copy) { mock.called }
                    generator.replace_by(new)
                    assert new.handlers.first.copy_on_replace?
                end
                it "copies the once flag" do
                    generator.once(on_replace: :copy) { mock.called }
                    generator.replace_by(new)
                    assert new.handlers.first.once?
                end
            end

            describe "unreachability handlers" do
                it "ignores handlers which have the drop-on-replace policy" do
                    generator.if_unreachable(on_replace: :drop) { mock.called }
                    generator.replace_by(new)
                    mock.should_receive(:called).never
                    execute { new.unreachable! }
                end
                it "copies handlers which have the copy-on-replace policy" do
                    generator.if_unreachable(on_replace: :copy) { mock.called }
                    generator.replace_by(new)
                    mock.should_receive(:called).once
                    execute { new.unreachable! }
                end
                it "sets the copy-on-replace policy on the copied handlers" do
                    generator.if_unreachable(on_replace: :copy) { mock.called }
                    generator.replace_by(new)
                    assert new.unreachable_handlers[0][1].copy_on_replace?
                end
                it "copies cancel_at_emission: true" do
                    generator.if_unreachable(cancel_at_emission: true, on_replace: :copy) {}
                    generator.replace_by(new)
                    assert new.unreachable_handlers[0][0]
                end
                it "copies cancel_at_emission: false" do
                    generator.if_unreachable(cancel_at_emission: false, on_replace: :copy) {}
                    generator.replace_by(new)
                    refute new.unreachable_handlers[0][0]
                end
            end
        end

        describe "#garbage!" do
            it "marks the event as unreachable" do
                plan.add(event = EventGenerator.new)
                execute { event.garbage! }
                assert event.unreachable?
            end
        end

        describe "#unreachable!" do
            it "resets the pending flag" do
                plan.add(event = EventGenerator.new {})
                execute { event.call }
                assert event.pending?
                execute { event.unreachable! }
                refute event.pending?
            end
        end

        describe "a finalized event" do
            attr_reader :event

            before do
                plan.add(@event = EventGenerator.new)
                execute { plan.remove_free_event(event) }
            end

            it "can use relation methods" do
                event.each_out_neighbour(EventStructure::Forwarding).to_a
            end
        end
    end
end
