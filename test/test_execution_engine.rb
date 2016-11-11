require 'roby/test/self'
require './test/mockups/tasks'
require 'utilrb/hash/slice'
require 'timecop'

module Roby
    describe ExecutionEngine do
        describe "event_ordering" do
            it "is not cleared if events without precedence relations are added to the plan" do
                flexmock(execution_engine.event_ordering).should_receive(:clear).never
                plan.add(EventGenerator.new)
            end
            it "is cleared if a new precedence relation is added between events in the plan" do
                parent, child = EventGenerator.new, EventGenerator.new
                plan.add [parent, child]
                flexmock(execution_engine.event_ordering).should_receive(:clear).once
                parent.add_precedence child
            end
            it "is cleared if events linked through the precedence relation are added to the plan" do
                parent, child = EventGenerator.new, EventGenerator.new
                parent.add_precedence child
                flexmock(execution_engine.event_ordering).should_receive(:clear).once
                plan.add parent
            end
            it "is not cleared when a precedence relation is removed" do
                parent, child = EventGenerator.new, EventGenerator.new
                plan.add [parent, child]
                parent.add_precedence child
                flexmock(execution_engine.event_ordering).should_receive(:clear).never
                parent.remove_precedence child
            end
        end

        describe "event propagation" do
            it "calls handlers before propagating signals" do
                source, target = EventGenerator.new, EventGenerator.new(true)
                plan.add(source)
                source.signals target
                mock = flexmock
                source.on { mock.called_source }
                target.on { mock.called_target(source.emitted?) }
                mock.should_receive(:called_source).once.globally.ordered
                mock.should_receive(:called_target).once.with(true).globally.ordered
                source.emit
            end

            it "calls handlers before propagating forwards" do
                source, target = EventGenerator.new, EventGenerator.new
                plan.add(source)
                source.forward_to target
                mock = flexmock
                source.on { mock.called_source }
                target.on { mock.called_target(source.emitted?) }
                mock.should_receive(:called_source).once.globally.ordered
                mock.should_receive(:called_target).once.with(true).globally.ordered
                source.emit
            end
        end

        it "removes queued emissions whose task event target has been finalized" do
            plan.add(task = Roby::Tasks::Simple.new)
            execution_engine.gather_propagation do
                task.start_event.emit
                plan.remove_task(task)
                assert !execution_engine.has_queued_events?
            end
        end

        it "removes queued emissions whose free event target has been finalized" do
            plan.add(generator = Roby::EventGenerator.new)
            execution_engine.gather_propagation do
                generator.emit
                plan.remove_free_event(generator)
                assert !execution_engine.has_queued_events?
            end
        end

        describe "promise handling" do
            it "queues promises in the #waiting_work list" do
                p = execution_engine.promise { }
                assert execution_engine.waiting_work.include?(p)
            end

            it "removes completed promises from #waiting_work" do
                p = execution_engine.promise { }
                p.on_error { }
                p.execute
                assert_equal [p], execution_engine.join_all_waiting_work
                refute execution_engine.waiting_work.include?(p)
            end

            it "leaves non-completed promises within #waiting_work" do
                p = execution_engine.promise { }
                flexmock(p).should_receive(:complete?).and_return(false)
                p.execute
                assert_equal [], execution_engine.process_waiting_work
                assert execution_engine.waiting_work.include?(p)
            end

            it "adds a promise error as a framework error if it is not handled" do
                e = ArgumentError.new
                p = execution_engine.promise { raise e }
                p.execute
                flexmock(execution_engine).should_receive(:add_framework_error).
                    with(e, String).once
                execution_engine.join_all_waiting_work
                refute execution_engine.waiting_work.include?(p)
            end

            it "does not add a handled promise error as a framework error" do
                e = ArgumentError.new
                p = execution_engine.promise { raise e }
                p.on_error { }
                p.execute
                flexmock(execution_engine).should_receive(:add_framework_error).never
                assert execution_engine.join_all_waiting_work.include?(p)
                refute execution_engine.waiting_work.include?(p)
            end
        end

        describe "#finalized_event" do
            it "marks the event as unreachable" do
                plan.add(event = Roby::EventGenerator.new)
                plan.remove_free_event(event)
                assert event.unreachable?
            end
            it "reports 'finalized' as the unreachability reason" do
                plan.add(event = Roby::EventGenerator.new)
                plan.remove_free_event(event)
                assert_equal 'finalized', event.unreachability_reason
            end
        end

        describe "#propagation_context" do
            it "sets the sources to the given set" do
                execution_engine.gather_propagation do
                    execution_engine.propagation_context(sources = [event = flexmock]) do
                        assert_equal [event], execution_engine.propagation_sources
                    end
                end
            end
            it "restores the sources to their original value if the block returns normally" do
                execution_engine.gather_propagation do
                    execution_engine.propagation_context(original_sources = [flexmock]) do
                        execution_engine.propagation_context(sources = [flexmock]) do
                            assert_equal sources, execution_engine.propagation_sources
                        end
                        assert_equal original_sources, execution_engine.propagation_sources
                    end
                end
            end
            it "restores the sources to their original value if the block raises" do
                assert_raises(RuntimeError) do
                    execution_engine.gather_propagation do
                        execution_engine.propagation_context(original_sources = [flexmock]) do
                            begin
                                execution_engine.propagation_context(sources = [flexmock]) do
                                    raise
                                end
                            ensure
                                assert_equal original_sources, execution_engine.propagation_sources
                            end
                        end
                    end
                end
            end
            it "raises if called outside a propagation context" do
                e = assert_raises(InternalError) do
                    execution_engine.propagation_context([]) do
                    end
                end
                assert_equal "not in a gathering context in #propagation_context",
                    e.message
            end
            it "leaves the sources to their value if the propagation context check triggers" do
                execution_engine.instance_variable_set(:@propagation_sources, sources = [flexmock])
                assert_raises(InternalError) do
                    execution_engine.propagation_context([]) { }
                end
                assert_equal sources, execution_engine.propagation_sources
            end
        end

        describe "#quit" do
            it "sets the quitting flag but not forced_exit?" do
                execution_engine.quit
                assert execution_engine.quitting?
                refute execution_engine.forced_exit?
                execution_engine.quit
                assert execution_engine.quitting?
                refute execution_engine.forced_exit?
            end
        end

        describe "#force_quit" do
            it "sets both quitting flag and forced_exit?" do
                execution_engine.force_quit
                assert execution_engine.quitting?
                assert execution_engine.forced_exit?
            end
        end

        describe "#reset" do
            it "resets the quitting flag" do
                execution_engine.quit
                execution_engine.reset
                refute execution_engine.quitting?
            end
            it "does nothing if the EE is not quitting" do
                execution_engine.reset
                refute execution_engine.quitting?
            end
        end

        describe "#event_loop" do
            describe "exit behaviour" do
                it "quits when receiving a Interrupt" do
                    execution_engine.once do
                        execution_engine.add_framework_error(Interrupt.exception, "test")
                    end
                    flexmock(execution_engine).should_expect do |m|
                        m.error.with_any_args
                        m.info.with_any_args
                        m.fatal("Received interruption request").once
                        m.fatal("Interrupt again in 10s to quit without cleaning up").once
                        m.clear.at_least.once
                    end
                    execution_engine.event_loop
                end

                it "does not forcefully quit when receiving two Interrupts closer than the dead zone parameter" do
                    Timecop.freeze do
                        # The plan is 'clean' when #clear returns nil
                        clear_return = []
                        flexmock(execution_engine).should_receive(:clear).and_return { clear_return }.
                            at_least.once
                        execution_engine.once do
                            execution_engine.add_framework_error(Interrupt.exception, "test")
                            execution_engine.once do
                                Timecop.freeze(5)
                                execution_engine.add_framework_error(Interrupt.exception, "test")
                                execution_engine.once do
                                    clear_return = nil
                                end
                            end
                        end
                        flexmock(execution_engine).should_expect do |m|
                            m.error.with_any_args
                            m.info.with_any_args
                            m.fatal("Received interruption request").once
                            m.fatal("Interrupt again in 10s to quit without cleaning up").once
                            m.fatal("Still 5s before interruption will quit without cleaning up").once
                        end
                        execution_engine.event_loop
                    end
                end

                it "does forcefully quit when receiving two Interrupts spaced by more than the dead zone parameter" do
                    Timecop.freeze do
                        # The plan is 'clean' when #clear returns nil
                        clear_return = []
                        flexmock(execution_engine).should_receive(:clear).and_return { clear_return }.
                            at_least.once
                        execution_engine.once do
                            execution_engine.add_framework_error(Interrupt.exception, "test")
                            execution_engine.once do
                                Timecop.freeze(12)
                                execution_engine.add_framework_error(Interrupt.exception, "test")
                            end
                        end
                        flexmock(execution_engine).should_expect do |m|
                            m.error.with_any_args
                            m.info.with_any_args
                            m.fatal("Received interruption request").once
                            m.fatal("Interrupt again in 10s to quit without cleaning up").once
                            m.fatal("Quitting without cleaning up").once
                        end
                        execution_engine.event_loop
                    end
                end
            end
        end
    end
end


class TC_ExecutionEngine < Minitest::Test
    def test_gather_propagation
	e1, e2, e3 = EventGenerator.new(true), EventGenerator.new(true), EventGenerator.new(true)
	plan.add [e1, e2, e3]

	set = execution_engine.gather_propagation do
	    e1.call(1)
	    e1.call(4)
	    e2.emit(2)
	    e2.emit(3)
	    e3.call(5)
	    e3.emit(6)
	end
	assert_equal(
            { e1 => [1, [], [nil, [1], nil, nil, [4], nil]],
              e2 => [3, [nil, [2], nil, nil, [3], nil], []],
              e3 => [5, [nil, [6], nil], [nil, [5], nil]] }, set)
    end

    class PropagationHandlerTest
        attr_reader :event
        attr_reader :plan

        def initialize(plan, mockup)
            @mockup = mockup
            @plan = plan
            reset_event
        end

        def reset_event
            plan.add_permanent_event(@event = Roby::EventGenerator.new(true))
        end

        def handler(plan)
            if @event.history.size != 2
                @event.call
            end
            @mockup.called(plan)
        end
    end

    def test_add_propagation_handlers_for_external_events
        FlexMock.use do |mock|
            handler = PropagationHandlerTest.new(plan, mock)
            id = execution_engine.add_propagation_handler(type: :external_events) { |plan| handler.handler(plan) }

            mock.should_receive(:called).with(plan).twice

            process_events
            assert_equal(1, handler.event.history.size)

            handler.reset_event
            process_events
            assert_equal(1, handler.event.history.size)

            execution_engine.remove_propagation_handler id
            handler.reset_event
            process_events
            assert_equal(0, handler.event.history.size)
        end
    end

    def test_add_propagation_handlers_for_propagation
        FlexMock.use do |mock|
            handler = PropagationHandlerTest.new(plan, mock)
            id = execution_engine.add_propagation_handler(type: :propagation) { |plan| handler.handler(plan) }

            # In the handler, we call the event two times
            #
            # The propagation handler should be called one time more (until
            # it does not emit any event), So it will be called 6 times over the
            # whole test
            mock.should_receive(:called).with(plan).times(6)

            process_events
            assert_equal(2, handler.event.history.size)

            handler.reset_event
            process_events
            assert_equal(2, handler.event.history.size)

            execution_engine.remove_propagation_handler id
            handler.reset_event
            process_events
            assert_equal(0, handler.event.history.size)
        end
    end

    def test_add_propagation_handlers_for_propagation_late
        FlexMock.use do |mock|
            plan.add_permanent_event(event = Roby::EventGenerator.new(true))
            plan.add_permanent_event(late_event = Roby::EventGenerator.new(true))

            index = -1
            event.on { |_| mock.event_emitted(index += 1) }
            late_event.on { |_| mock.late_event_emitted(index += 1) }


            id = execution_engine.add_propagation_handler(type: :propagation) do |plan|
                mock.handler_called(index += 1)
                if !event.emitted?
                    event.emit
                end
            end
            late_id = execution_engine.add_propagation_handler(type: :propagation, late: true) do |plan|
                mock.late_handler_called(index += 1)
                if !late_event.emitted?
                    late_event.emit
                end
            end

            mock.should_receive(:handler_called).with(0).once.ordered
            mock.should_receive(:event_emitted).with(1).once.ordered
            mock.should_receive(:handler_called).with(2).once.ordered
            mock.should_receive(:late_handler_called).with(3).once.ordered
            mock.should_receive(:late_event_emitted).with(4).once.ordered
            mock.should_receive(:handler_called).with(5).once.ordered
            mock.should_receive(:late_handler_called).with(6).once.ordered

            process_events
            execution_engine.remove_propagation_handler(id)
            execution_engine.remove_propagation_handler(late_id)
            process_events
        end
    end

    def test_add_propagation_handlers_accepts_method_object
        FlexMock.use do |mock|
            handler = PropagationHandlerTest.new(plan, mock)
            id = execution_engine.add_propagation_handler(type: :external_events, &handler.method(:handler))

            mock.should_receive(:called).with(plan).twice
            process_events
            process_events
            execution_engine.remove_propagation_handler id
            process_events

            assert_equal(2, handler.event.history.size)
        end
    end

    def test_add_propagation_handler_validates_arity
        mock = flexmock
        # Validate the arity
        assert_raises(ArgumentError) do
            execution_engine.add_propagation_handler(&lambda { |plan, failure| mock.called(plan) })
        end

        process_events
    end

    def test_propagation_handlers_raises_on_error
        FlexMock.use do |mock|
            execution_engine.add_propagation_handler do |plan|
                mock.called
                raise SpecificException
            end
            mock.should_receive(:called).once
            assert_raises(SpecificException) { process_events }
        end
    end

    def test_propagation_handlers_disabled_on_error
        FlexMock.use do |mock|
            execution_engine.add_propagation_handler on_error: :disable do |plan|
                mock.called
                raise
            end
            mock.should_receive(:called).once
            process_events
            process_events
        end
    end

    def test_propagation_handlers_ignore_on_error
        spy = flexmock { |s| s.should_receive(:called).twice }

        handler = execution_engine.add_propagation_handler on_error: :ignore do |plan|
            spy.called
            raise
        end
        process_events
        process_events
    ensure
        execution_engine.remove_propagation_handler(handler) if handler
    end

    def test_prepare_propagation
	g1, g2 = EventGenerator.new(true), EventGenerator.new(true)
	ev = Event.new(g2, 0, nil)

	step = [nil, [1], nil, nil, [4], nil]
	source_events, source_generators, context = execution_engine.prepare_propagation(nil, false, step)
	assert_equal(Set.new, source_events)
	assert_equal(Set.new, source_generators)
	assert_equal([1, 4], context)

	step = [nil, [], nil, nil, [4], nil]
	source_events, source_generators, context = execution_engine.prepare_propagation(nil, false, step)
	assert_equal(Set.new, source_events)
	assert_equal(Set.new, source_generators)
	assert_equal([4], context)

	step = [g1, [], nil, ev, [], nil]
	source_events, source_generators, context = execution_engine.prepare_propagation(nil, false, step)
	assert_equal([g1, g2].to_set, source_generators)
	assert_equal([ev].to_set, source_events)
	assert_equal([], context)

	step = [g2, [], nil, ev, [], nil]
	source_events, source_generators, context = execution_engine.prepare_propagation(nil, false, step)
	assert_equal([g2].to_set, source_generators)
	assert_equal([ev].to_set, source_events)
	assert_equal([], context)
    end

    def test_next_step
	# For the test to be valid, we need +pending+ to have a deterministic ordering
	# Fix that here
	e1, e2, e3 = EventGenerator.new(true), EventGenerator.new(true), EventGenerator.new(true)
	plan.add [e1, e2, e3]

        pending = Array.new
	def pending.each_key; each { |(k, v)| yield(k) } end
	def pending.delete(ev)
            value = find { |(k, v)| k == ev }.last
            delete_if { |(k, v)| k == ev }
            value
        end

        # If there is no precedence, the order is determined by
        # forwarding/signalling and/or step_id
        pending.clear
	pending << [e1, [0, [], [flexmock]]] << [e2, [1, [flexmock], []]]
	assert_equal(e2, execution_engine.next_event(pending).first)
        pending.clear
	pending << [e1, [1, [flexmock], []]] << [e2, [0, [flexmock], []]]
	assert_equal(e2, execution_engine.next_event(pending).first)

        # If there *is* a precedence relation, we must follow it
        pending.clear
	pending << [e1, [0, [flexmock], []]] << [e2, [1, [flexmock], []]]

	e1.add_precedence e2
	assert_equal(e1, execution_engine.next_event(pending).first)
	e1.remove_precedence e2
	e2.add_precedence e1
	assert_equal(e2, execution_engine.next_event(pending).first)
    end

    def test_delay
        time_proxy = flexmock(Time)
        current_time = Time.now + 5
        time_proxy.should_receive(:now).and_return { current_time }

        plan.add_mission_task(t = Tasks::Simple.new)
        e = EventGenerator.new(true)
        t.event(:start).signals e, delay: 0.1
        execution_engine.once { t.start! }
        process_events
        assert(!e.emitted?)
        current_time += 0.2
        process_events
        assert(e.emitted?)
    end

    def test_delay_with_unreachability
        time_proxy = flexmock(Time)
        current_time = Time.now + 5
        time_proxy.should_receive(:now).and_return { current_time }

        source, sink0, sink1 = prepare_plan permanent: 3, model: Tasks::Simple
        source.start_event.signals sink0.start_event, delay: 0.1
        source.start_event.signals sink1.start_event, delay: 0.1
        source.start!
        assert(!sink0.start_event.emitted?)
        assert(!sink1.start_event.emitted?)

        plan.remove_task(sink0)
        plan.unmark_permanent_task(sink1)
        sink1.failed_to_start!("test")
        assert(sink0.start_event.unreachable?)
        assert(sink1.start_event.unreachable?)
        assert(! execution_engine.delayed_events.
               find { |_, _, _, target, _| target == sink0.start_event })
        assert(! execution_engine.delayed_events.
               find { |_, _, _, target, _| target == sink1.start_event })

        current_time += 0.1
        # Avoid unnecessary error messages
        plan.unmark_permanent_task(sink0)
        plan.unmark_permanent_task(sink1)
    end

    def test_duplicate_signals
	plan.add_mission_task(t = Tasks::Simple.new)
	
	FlexMock.use do |mock|
            t.start_event.on   { |event| t.success_event.emit(*event.context) }
	    t.start_event.on   { |event| t.success_event.emit(*event.context) }

	    t.success_event.on { |event| mock.success(event.context) }
	    t.stop_event.on    { |event| mock.stop(event.context) }
	    mock.should_receive(:success).with([42, 42]).once.ordered
	    mock.should_receive(:stop).with([42, 42]).once.ordered
	    t.start!(42)
	end
    end

    def test_default_task_ordering
	a = Tasks::Simple.new_submodel do
	    event :intermediate
	end.new(id: 'a')

	plan.add_mission_task(a)
	a.depends_on(b = Tasks::Simple.new(id: 'b'))

	b.success_event.forward_to a.intermediate_event
	b.success_event.forward_to a.success_event

	FlexMock.use do |mock|
            b.success_event.on { |ev| mock.child_success }
	    a.intermediate_event.on { |ev| mock.parent_intermediate }
	    a.success_event.on { |ev| mock.parent_success }
	    mock.should_receive(:child_success).once.ordered
	    mock.should_receive(:parent_intermediate).once.ordered
	    mock.should_receive(:parent_success).once.ordered
	    a.start!
	    b.start!
	    b.success!
	end
    end

    def test_process_events_diamond_structure
	a = Tasks::Simple.new_submodel do
	    event :child_success
	    event :child_stop
	    forward child_success: :child_stop
	end.new(id: 'a')

	plan.add_mission_task(a)
	a.depends_on(b = Tasks::Simple.new(id: 'b'))

	b.success_event.forward_to a.child_success_event
	b.stop_event.forward_to a.child_stop_event

	FlexMock.use do |mock|
	    a.child_stop_event.on { |ev| mock.stopped }
	    mock.should_receive(:stopped).once.ordered
	    a.start!
	    b.start!
	    b.success!
	end
    end

    def test_signal_forward
	forward = EventGenerator.new(true)
	signal  = EventGenerator.new(true)
	plan.add [forward, signal]

	FlexMock.use do |mock|
	    sink = EventGenerator.new do |context|
		mock.command_called(context)
		sink.emit(42)
	    end
	    sink.on { |event| mock.handler_called(event.context) }

	    forward.forward_to sink
	    signal.signals   sink

	    seeds = execution_engine.gather_propagation do
		forward.call(24)
		signal.call(42)
	    end
	    mock.should_receive(:command_called).with([42]).once.ordered
	    mock.should_receive(:handler_called).with([42, 24]).once.ordered
	    execution_engine.event_propagation_phase(seeds)
	end
    end

    describe "#add_framework_error" do
        it "raises NotPropagationContext if called outside of a gathering context" do
            assert_raises(Roby::ExecutionEngine::NotPropagationContext) do
                execution_engine.add_framework_error(RuntimeError.exception("test"), :exceptions)
            end
        end

        it "registers the exception in the application exceptions set" do
            expected_error = Class.new(RuntimeError).exception("test error message")
            errors = execution_engine.gather_framework_errors("test", raise_caught_exceptions: false) do
                execution_engine.add_framework_error(expected_error, :exceptions) 
            end
            assert_equal 1, errors.size
            error, context = errors.first
            assert_equal :exceptions, context
            assert_kind_of expected_error.class, error
            assert_equal "test error message", error.message
        end
    end

    def test_event_loop
        plan.add_mission_task(start_node = EmptyTask.new)
        next_event = [ start_node, :start ]
        plan.add_mission_task(if_node    = ChoiceTask.new)
        start_node.stop_event.on { |ev| next_event = [if_node, :start] }
	if_node.stop_event.on { |ev| }
            
        execution_engine.add_propagation_handler(type: :external_events) do |plan|
            next unless next_event
            task, event = *next_event
            next_event = nil
            task.event(event).call(nil)
        end
        process_events
        assert(start_node.finished?)
	
        process_events
	assert(if_node.finished?)
    end

    def test_every
        time = Time.now
        flexmock(Time).should_receive(:now).and_return { time }

	# Check that every(cycle_length) works fine
	samples = []
	id = execution_engine.every(0.1) do
	    samples << execution_engine.cycle_start
	end

        expected_samples = Array.new
        expected_samples << time
        process_events
        expected_samples << (time += 0.12)
        process_events
        process_events
        process_events
        expected_samples << (time += 0.1)
        process_events
        process_events
	execution_engine.remove_periodic_handler(id)
        process_events
        assert_equal expected_samples, samples, "expected #{expected_samples.map { |t| Roby.format_time(t) }}, got #{samples.map { |t| Roby.format_time(t) }}"
    end

    def test_once_blocks_are_called_by_proces_events
	FlexMock.use do |mock|
	    execution_engine.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	end
    end
    def test_once_blocks_are_called_only_once
	FlexMock.use do |mock|
	    execution_engine.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	    process_events
	end
    end

    def test_failing_once
        spy = flexmock
        spy.should_receive(:called).once
        execution_engine.once { spy.called; raise }

        assert_raises(RuntimeError) do
            process_events
        end
    end

    class SpecificException < RuntimeError; end

    def apply_check_structure(&block)
	Plan.structure_checks.clear
	Plan.structure_checks << lambda(&block)
	process_events
    ensure
	Plan.structure_checks.clear
    end

    def test_check_structure_handlers_are_propagated_twice
        # First time, we don't do anything. Second time, we return some filtered
        # fatal errors and verify that they are handled
	Plan.structure_checks.clear
        t0, t1, t2 = prepare_plan add: 3
        t1.depends_on t0
        errors = Hash[LocalizedError.new(t0).to_execution_exception => [t1]]
        plan.structure_checks.clear
        handler = proc { errors }
	Plan.structure_checks << handler

        execution_engine = flexmock(self.execution_engine)
        execution_engine.should_receive(:propagate_exceptions).with([]).and_return([[], Hash.new])
        execution_engine.should_receive(:propagate_exceptions).with(errors).and_return([[], Hash.new]).once
        execution_engine.should_receive(:remove_inhibited_exceptions).with(errors).
            and_return([[e = LocalizedError.new(t0), Set[t2]]])
        errors = execution_engine.compute_errors([])
        assert_equal Hash[e, Set[t2]], errors.fatal_errors
            
    ensure
        Plan.structure_checks.delete(handler) if handler
    end

    def test_at_cycle_end
        Roby.app.abort_on_application_exception = false

        mock = flexmock
        mock.should_receive(:before_error).at_least.once
        mock.should_receive(:after_error).never
        mock.should_receive(:called).at_least.once

        handler0 = execution_engine.at_cycle_end do
            mock.before_error
            raise
            mock.after_error
        end

        handler1 = execution_engine.at_cycle_end do
            mock.called
            unless execution_engine.quitting?
                execution_engine.quit
            end
        end

        process_events
        process_events
    ensure
        execution_engine.remove_at_cycle_end(handler0)
        execution_engine.remove_at_cycle_end(handler1)
    end

    def test_inside_outside_control
	# First, no control thread
	assert(execution_engine.inside_control?)
	assert(!execution_engine.outside_control?)

        t = Thread.new do
            assert(!execution_engine.inside_control?)
            assert(execution_engine.outside_control?)
        end
        t.value
    end

    def test_execute
	FlexMock.use do |mock|
	    mock.should_receive(:thread_before).once.ordered
	    mock.should_receive(:main_before).once.ordered
	    mock.should_receive(:execute).once.ordered.with(Thread.current).and_return(42)
	    mock.should_receive(:main_after).once.ordered(:finish)
	    mock.should_receive(:thread_after).once.ordered(:finish)

	    returned_value = nil
	    t = Thread.new do
		mock.thread_before
		returned_value = execution_engine.execute do
		    mock.execute(Thread.current)
		end
		mock.thread_after
	    end

	    # Wait for the thread to block
	    while !t.stop?; sleep(0.01) end
	    mock.main_before
	    assert(t.alive?)
            # We use execution_engine.process_events as we are making the execution_engine
            # believe that it is running while it is not
	    execution_engine.process_events
	    mock.main_after
	    t.join

	    assert_equal(42, returned_value)
	end
    end

    def test_execute_error
	assert(!execution_engine.quitting?)

	returned_value = nil
	t = Thread.new do
	    returned_value = begin
				 execution_engine.execute do
				     raise ArgumentError
				 end
			     rescue ArgumentError => e
				 e
			     end
	end

	# Wait for the thread to block
	while !t.stop?; sleep(0.01) end
        assert(t.alive?)
        # We use execution_engine.process_events as we are making the execution_engine
        # believe that it is running while it is not
	execution_engine.process_events
	t.join

	assert_kind_of(ArgumentError, returned_value)
	assert(!execution_engine.quitting?)
    end
    
    def test_wait_until
	plan.add_permanent_task(task = Tasks::Simple.new)
	t = Thread.new do
	    execution_engine.wait_until(task.start_event) do
		task.start!
	    end
	end

	while !t.stop?; sleep(0.01) end
        # We use execution_engine.process_events as we are making the execution_engine
        # believe that it is running while it is not
	execution_engine.process_events
	t.value
    end
 
    def test_wait_until_unreachable
	plan.add_permanent_task(task = Tasks::Simple.new)
	t = Thread.new do
	    begin
		execution_engine.wait_until(task.event(:success)) do
		    task.start!
                    task.stop!
		end
	    rescue Exception => e
		e
	    end
	end

        # Wait for #wait_until, in the thread, to wait for the main thread
	while !t.stop?; sleep(0.01) end
        # And process the events
        #
        # We use execution_engine.process_events as we are making the execution_engine
        # believe that it is running while it is not
        execution_engine.process_events

	result = t.value
	assert_kind_of(UnreachableEvent, result)
	assert_equal(task.event(:success), result.failed_generator)
    end
    
    def test_stats
	time_events = [:actual_start, :events, :structure_check, :exception_propagation, :exception_fatal, :garbage_collect, :application_errors, :ruby_gc, :sleep, :end]
	10.times do
            FlexMock.use(execution_engine) do |mock|
                mock.should_receive(:cycle_end).and_return do |stats|
                    timepoints = stats.slice(*time_events)
                    assert(timepoints.all? { |name, d| d > 0 })

                    sorted_by_time = timepoints.sort_by { |name, d| d }
                    sorted_by_name = timepoints.sort_by { |name, d| time_events.index(name) }
                    sorted_by_time.each_with_index do |(name, d), i|
                        assert(sorted_by_name[i][1] == d)
                    end
                end
                execution_engine.process_events
            end
	end
    end

    def assert_finalizes(plan, finalized, unneeded = nil)
        FlexMock.use(plan) do |mock|
            if finalized.empty?
                mock.should_receive(:finalized_task).never
                mock.should_receive(:finalized_event).never
            else
                finalized.each do |obj|
                    if obj.respond_to?(:to_task)
                        mock.should_receive(:finalized_task).with(obj).once
                    else
                        mock.should_receive(:finalized_event).with(obj).once
                    end
                end
            end

            yield if block_given?

            execution_engine.garbage_collect
            execution_engine.garbage_collect
            if unneeded
                assert_equal(unneeded.to_set, plan.unneeded_tasks.to_set)
            end
        end
    end

    def test_garbage_collect_tasks
	klass = Task.new_submodel do
	    attr_accessor :delays

	    event(:start, command: true)
	    event(:stop) do |context|
		if delays
		    return
		else
		    stop_event.emit
		end
            end
	end

        (m1, m2, m3), (t1, t2, t3, t4, t5, p1) =
            prepare_plan missions: 3, add: 6, model: klass
        dependency_chain m1, t1, t2
        dependency_chain m2, t1
        dependency_chain m3, t2
        m3.planned_by p1
        p1.depends_on t3
	t4.depends_on t5

	plan.add_permanent_task(t4)

	assert_finalizes(plan, [])
	assert_finalizes(plan, [m1]) { plan.unmark_mission_task(m1) }
	assert_finalizes(plan, [m2, t1]) do
	    m2.start!
	    plan.unmark_mission_task(m2)
	end

	assert_finalizes(plan, [], [m3, p1, t3, t2]) do
	    m3.delays = true
	    m3.start!
	    plan.unmark_mission_task(m3)
	end
	assert(m3.event(:stop).pending?)
	assert_finalizes(plan, [m3, p1, t3, t2]) do
	    m3.stop_event.emit
	end
    ensure
        t5.stop_event.emit if t5.delays && t5.running?
    end
    
    def test_force_garbage_collect_tasks
	t1 = Task.new_submodel do
	    event(:stop) { |context| }
	end.new
	t2 = Task.new
	t1.depends_on t2

	plan.add_mission_task(t1)
	t1.start!
	assert_finalizes(plan, []) do
	    execution_engine.garbage_collect([t1])
	end
	assert(t1.event(:stop).pending?)

	assert_finalizes(plan, [t1, t2]) do
	    # This stops the mission, which will be automatically discarded
            t1.stop_event.emit
	end
    end

    def test_gc_ignores_incoming_events
	Roby::Plan.logger.level = Logger::WARN
	a, b = prepare_plan discover: 2, model: Tasks::Simple
        a.stop_event.signals b.stop_event
	a.start!

	process_events
	process_events
	assert(!a.plan)
	assert(!b.plan)
	assert(!b.event(:start).emitted?)
    end

    # Test a setup where there is both pending tasks and running tasks. This
    # checks that #stop! is called on all the involved tasks. This tracks
    # problems related to bindings in the implementation of #garbage_collect:
    # the killed task bound to the Roby.once block must remain the same.
    def test_gc_stopping
	Roby::Plan.logger.level = Logger::WARN
	running_task = nil
	FlexMock.use do |mock|
	    task_model = Task.new_submodel do
		event :start, command: true
		event :stop do |context|
		    mock.stop(self)
		end
	    end

	    running_tasks = (1..5).map do
		task_model.new
	    end

	    plan.add(running_tasks)
	    t1, t2 = Roby::Task.new, Roby::Task.new
	    t1.depends_on t2
	    plan.add(t1)

	    running_tasks.each do |t|
		t.start!
		mock.should_receive(:stop).with(t).once
	    end
		
	    execution_engine.garbage_collect
	    process_events

	    assert(!plan.has_task?(t1))
	    assert(!plan.has_task?(t2))
	    running_tasks.each do |t|
		assert(t.finishing?)
		t.stop_event.emit
	    end

	    execution_engine.garbage_collect
	    running_tasks.each do |t|
		assert(!plan.has_task?(t))
	    end
	end

    ensure
	running_task.stop_event.emit if running_task && !running_task.finished?
    end

    def test_garbage_collect_events
	t  = Tasks::Simple.new
	e1 = EventGenerator.new(true)

	plan.add_mission_task(t)
	plan.add(e1)
	assert_equal([e1], plan.unneeded_events.to_a)
	t.event(:start).signals e1
	assert_equal([], plan.unneeded_events.to_a)

	e2 = EventGenerator.new(true)
	plan.add(e2)
	assert_equal([e2], plan.unneeded_events.to_a)
	e1.forward_to e2
	assert_equal([], plan.unneeded_events.to_a)

	plan.remove_task(t)
	assert_equal([e1, e2].to_set, plan.unneeded_events)

        plan.add_permanent_event(e1)
	assert_equal([], plan.unneeded_events.to_a)
        plan.unmark_permanent_event(e1)
	assert_equal([e1, e2].to_set, plan.unneeded_events)
        plan.add_permanent_event(e2)
	assert_equal([], plan.unneeded_events.to_a)
        plan.unmark_permanent_event(e2)
	assert_equal([e1, e2].to_set, plan.unneeded_events)
    end

    Roby::TaskStructure.relation :WeakTest, weak: true

    def test_garbage_collect_weak_relations
        planning, planned, influencing = prepare_plan discover: 3, model: Tasks::Simple

        # Create a cycle with a weak relation
        planned.planned_by planning
        influencing.depends_on planned
        planning.add_weak_test influencing

        planned.start!
        planning.start!
        influencing.start!
        
        process_events
	assert(plan.tasks.empty?)
    end

    def test_mission_failed
	model = Tasks::Simple.new_submodel do
	    event :specialized_failure, command: true
	    forward specialized_failure: :failed
	end

	task = prepare_plan missions: 1, model: model
	task.start!
        
        error = assert_raises(Roby::MissionFailedError) { task.specialized_failure! }
	
	assert_kind_of(Roby::MissionFailedError, error)
	assert_equal(task.event(:specialized_failure).last, error.failure_point)
        Roby.format_exception error
    end

    def test_forward_signal_ordering
        100.times do
            stop_called = false
            source = Tasks::Simple.new(id: 'source')
            target = Tasks::Simple.new_submodel do
                event :start do |context|
                    if !stop_called
                        raise ArgumentError, "ordering failed"
                    end
                    start_event.emit
                end
            end.new(id: 'target')
            plan.add(source)
            plan.add(target)

            source.success_event.signals target.start_event
            source.stop_event.on do |ev|
                stop_called = true
            end
            source.start!
            source.success_event.emit
            assert(target.running?)
            target.stop!
        end
    end

    def test_delayed_block
        time_mock = flexmock(Time)
        time = Time.now
        time_mock.should_receive(:now).and_return { time }

        recorder = flexmock
        recorder.should_receive(:triggered).once.with(time + 6)
        execution_engine.delayed(5) { recorder.triggered(Time.now) }
        process_events
        time = time + 2
        process_events
        time = time + 4
        process_events
    end

    def test_one_can_add_errors_during_garbage_collection
        plan = flexmock(self.plan)
        plan.add(task = Roby::Tasks::Simple.new)
        task.stop_event.when_unreachable do
            execution_engine.add_error LocalizedError.new(task)
        end
        process_events(raise_errors: false)
    end

    class SpecializedError < LocalizedError; end

    def test_pass_exception_ignores_a_handler
        mock = flexmock
        klass = Task.new_submodel
        klass.on_exception(SpecializedError) do |exception|
            mock.called
            pass_exception
        end

        plan.add(task  = klass.new)
        error = ExecutionException.new(SpecializedError.new(task))
        mock.should_receive(:called).once
        assert(!task.handle_exception(error))
    end

    def test_task_handlers_are_called_in_the_inverse_declaration_order
	mock = flexmock

        received_handler2 = false
        klass = Task.new_submodel do 
            on_exception(SpecializedError) do |exception|
                mock.handler1(exception, self)
            end
            on_exception(SpecializedError) do |exception|
                mock.handler2(exception, self)
                pass_exception
            end
        end

        plan.add(task  = klass.new)
        error = ExecutionException.new(SpecializedError.new(task))
        mock.should_receive(:handler2).with(error, task).once.ordered
        mock.should_receive(:handler1).with(error, task).once.ordered
        assert task.handle_exception(error)
    end

    def make_task_with_handler(exception_matcher, mock)
        Task.new_submodel do 
            on_exception(exception_matcher) do |exception|
                mock.handler(exception, self)
            end
        end.new
    end

    def test_it_filters_handlers_on_the_exception_model
        mock = flexmock

        t1, t2 = prepare_plan add: 2
        t0 = make_task_with_handler(SpecializedError, mock)
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))
        mock.should_receive(:handler).once.
            with(on { |e| e.trace == [t2, t1, t0] && e.origin == t2 }, t0)
        assert_equal([[], Hash.new], execution_engine.propagate_exceptions([error]))
    end

    def test_it_ignores_handlers_that_do_not_match_the_filter
        t1, t2 = prepare_plan add: 2
        t0 = make_task_with_handler(CodeError, nil)
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))

        remaining, _ = execution_engine.propagate_exceptions([error])
        assert_equal 1, remaining.size
        remaining_error, affected_tasks = remaining.first
        assert_equal error, remaining_error
        assert_equal error.trace.to_set, affected_tasks.to_set
    end

    def test_it_does_not_call_global_handlers_if_the_exception_is_handled_by_a_task
        mock = flexmock

        t1, t2 = prepare_plan add: 3
        t0 = make_task_with_handler(SpecializedError, mock)
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))
        plan.on_exception(SpecializedError) do |p, e|
            mock.handler(e, p)
        end
        mock.should_receive(:handler).with(error, t0).once
        mock.should_receive(:handler).with(error, plan).never
        assert_equal([[], Hash.new], execution_engine.propagate_exceptions([error]))
    end

    def test_it_notifies_about_exceptions_handled_by_a_task
        mock = flexmock
        task_model = Roby::Task.new_submodel do
            on_exception(SpecializedError) { |e| }
        end
        plan.add(t0 = task_model.new)
        plan.add(t1 = Tasks::Simple.new)
        t0.depends_on(t1)

        error = ExecutionException.new(SpecializedError.new(t1))
        execution_engine.on_exception do |kind, error, involved_objects|
            mock.notified(kind, error.exception, involved_objects.to_set)
        end
        mock.should_receive(:notified).once.
            with(Roby::ExecutionEngine::EXCEPTION_HANDLED, error.exception, Set[t0])
        assert_equal([[], Hash.new], execution_engine.propagate_exceptions([error]))
    end

    def test_it_notifies_about_exceptions_handled_by_the_plan
        mock = flexmock
        t0, t1 = prepare_plan add: 3
        t0.depends_on(t1)

        error = ExecutionException.new(SpecializedError.new(t1))
        plan.on_exception(SpecializedError) {}
        execution_engine.on_exception do |kind, error, involved_objects|
            mock.notified(kind, error.exception, involved_objects.to_set)
        end
        mock.should_receive(:notified).once.
            with(Roby::ExecutionEngine::EXCEPTION_HANDLED, error.exception, Set[plan])
        assert_equal([[], Hash.new], execution_engine.propagate_exceptions([error]))
    end

    def test_it_uses_global_handlers_to_filter_exceptions_that_have_not_been_handled_by_a_task
        mock = flexmock

        t0, t1, t2 = prepare_plan add: 3
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))
        plan.on_exception(SpecializedError) do |p, e|
            mock.handler(e, p)
        end
        mock.should_receive(:handler).with(error, plan).once
        assert_equal([[], Hash.new], execution_engine.propagate_exceptions([error]))
    end

    def dependency_chain(*tasks)
        plan.add(tasks.first)
        tasks.each_cons(2) do |from, to|
            from.depends_on to
        end
    end

    def test_propagate_exceptions_forked_propagation
	# We build a 0 -> 1 -> 2 3 -> 2 task tree with
	# 0 being able to handle the exception and 1, 3 not

	recorder = flexmock

        t1, t2, t3 = prepare_plan add: 3
        t0 = Task.new_submodel do 
            on_exception(Roby::CodeError) do |exception|
                recorder.handler(exception, exception.trace, self)
            end
        end.new
        execution_engine.on_exception do |kind, exception, tasks|
            recorder.on_exception(kind, exception, tasks)
        end
        dependency_chain t0, t1, t2
        dependency_chain t3, t2

        recorder.should_receive(:handler).once.
            with(ExecutionException, [t2, t1, t0], t0)
        recorder.should_receive(:on_exception).once.
            with(ExecutionEngine::EXCEPTION_HANDLED, on { |e| e.trace == [t2, t1, t0] }, Set[t0])

        error = ExecutionException.new(CodeError.new(nil, t2))
        fatal, _ = execution_engine.propagate_exceptions([error])
        assert_equal 1, fatal.size

        exception, affected_tasks = fatal.first
        assert_equal [t2, t3], exception.trace
        assert_equal [t3], affected_tasks
    end

    def test_propagate_exceptions_diamond_propagation
        mock = flexmock

        t11, t12, t2 = prepare_plan add: 3

        t0 = Task.new_submodel do 
            on_exception(Roby::LocalizedError) do |exception|
                mock.handler(exception, self)
            end
        end.new
        dependency_chain(t0, t11, t2)
        dependency_chain(t0, t12, t2)

        error = ExecutionException.new(LocalizedError.new(t2))
        mock.should_receive(:handler).once.
            with(on { |e| e.trace.flatten.to_set == [t0, t2, t12, t11].to_set && e.origin == t2 }, t0)
        assert_equal([[], Hash.new], execution_engine.propagate_exceptions([error]))
    end

    # Tests exception handling mechanism during event propagation
    def test_task_propagation_with_exception
	Roby.app.abort_on_exception = true

	task = Tasks::Simple.new_submodel do
	    event :start do |context|
		start_event.emit
		raise RuntimeError, "failed"
            end
	end.new(id: 'child')

	FlexMock.use do |mock|
	    parent = Tasks::Simple.new_submodel do
		on_exception ChildFailedError do |exception|
		    mock.exception
		    task.pass_exception
		end
	    end.new(id: 'parent')
	    mock.should_receive(:exception).once

	    parent.depends_on task
	    plan.add_permanent_task(parent)
            
	    execution_engine.once { parent.start!; task.start! }

	    mock.should_receive(:other_once_handler).once
	    mock.should_receive(:other_event_processing).once
	    execution_engine.once { mock.other_once_handler }
	    execution_engine.add_propagation_handler(type: :external_events) { |plan| mock.other_event_processing }

            assert_raises(Roby::ChildFailedError) do
		process_events
	    end
	end
	assert(task.event(:start).emitted?)
    end

    def test_exception_argument_count_validation
        assert_raises(ArgumentError) do
            Task.new_submodel.on_exception(RuntimeError) do |a, b|
            end
        end
        Task.new_submodel.on_exception(RuntimeError) do |_|
        end
    end

    def test_error_handling_relation(error_event = :failed)
	task_model = Tasks::Simple.new_submodel do
	    event :blocked
	    forward blocked: :failed
	end

	parent, (child, *repair_tasks) = prepare_plan permanent: 1, add: 3, model: task_model
	parent.depends_on child
	child.event(:failed).handle_with repair_tasks[0]

	parent.start!
	child.start!
        child.event(error_event).emit

	exceptions = plan.check_structure
        assert execution_engine.remove_inhibited_exceptions(exceptions).empty?
        assert_equal([[], Hash.new], execution_engine.propagate_exceptions(exceptions))

        repairs = child.find_all_matching_repair_tasks(child.terminal_event)
        assert_equal 1, repairs.size
        repair_task = repairs.first

	Roby.app.abort_on_exception = false
        # Verify that both the repair and root tasks are not garbage collected
	process_events
	assert(repair_task.running?)

	# Make the "repair task" finish, but do not repair the plan.
	# propagate_exceptions must not add a new repair
        assert_raises(ChildFailedError) do
            repair_task.success!
        end

    ensure
	parent.remove_child child if child
    end

    def test_error_handling_relation_generalization
	test_error_handling_relation(:blocked)
    end

    def test_error_handling_relation_with_as_plan
        model = Tasks::Simple.new_submodel do
            def self.as_plan
                new(id: 10)
            end
        end
        task = prepare_plan add: 1, model: Tasks::Simple
        child = task.failed_event.handle_with(model)
        assert_kind_of model, child
        assert_equal 10, child.arguments[:id]
    end

    def test_mission_exceptions
	mission = prepare_plan missions: 1, model: Tasks::Simple
	mission.start!
        error = assert_raises(MissionFailedError) { mission.failed_event.emit }

	assert_kind_of(Roby::MissionFailedError, error)
    end

    def test_command_failed_formatting
        plan.add(task = Roby::Task.new)
        Roby.format_exception(CommandFailed.new(RuntimeError.new("message"), task.start_event))
    end

    def test_emission_failed_formatting
        plan.add(task = Roby::Task.new)
        Roby.format_exception(EmissionFailed.new(RuntimeError.new("message"), task.start_event))
    end

    def test_event_handler_error_formatting
        plan.add(task = Roby::Task.new)
        Roby.format_exception(EventHandlerError.new(RuntimeError.new("message"), task.start_event))
    end

    def test_nonfatal_exception_handling
        task_model = Tasks::Simple.new_submodel
        plan.add_permanent_task(t = task_model.new)
        t.start!

        mock = flexmock
        execution_engine.on_exception do |kind, error, involved_objects|
            mock.notified(kind, error.exception, involved_objects.to_set)
        end
        mock.should_receive(:notified).once.
            with(ExecutionEngine::EXCEPTION_NONFATAL, PermanentTaskError, [t].to_set)

        messages = capture_log(execution_engine, :warn) do
            assert_raises(PermanentTaskError) do
                t.failed_event.emit
            end
        end
        assert_equal ["1 unhandled non-fatal exceptions"], messages
    end

    def test_fatal_exception_handling
        task_model = Tasks::Simple.new_submodel do
            event :intermediate do |context|
                intermediate_event.emit
            end
        end
        
        t1, t2, t3 = prepare_plan add: 3, model: task_model
        t1.depends_on t2
        t2.depends_on t3, failure: [:intermediate]

        t1.start!
        t2.start!
        t3.start!

        mock = flexmock
        execution_engine.on_exception do |kind, error, involved_objects|
            mock.notified(kind, error.exception, involved_objects.to_set)
        end
        mock.should_receive(:notified).once.
            with(ExecutionEngine::EXCEPTION_FATAL, ChildFailedError, [t1, t2, t3].to_set)

        assert_raises(ChildFailedError) do
            t3.intermediate!
        end
    end

    def test_permanent_task_errors_are_nonfatal
        task = prepare_plan permanent: 1, model: Tasks::Simple

        mock = flexmock
        mock.should_receive(:called).once.with(false)

        plan.on_exception(PermanentTaskError) do |plan, error|
            plan.unmark_permanent_task(error.task)
            mock.called(error.fatal?)
        end

        task.start!
        task.stop!
    end

    def test_it_propagates_exceptions_only_through_the_listed_parents
        mock = flexmock
        task_model = Task.new_submodel do
            on_exception LocalizedError do |error|
                mock.called(self)
                pass_exception
            end
        end
        a0, a1 = prepare_plan add: 2, model: task_model
        plan.add(b = Roby::Task.new)
        a0.depends_on b
        a1.depends_on b
        mock.should_receive(:called).with(a0).once
        mock.should_receive(:called).with(a1).never
        execution_engine.propagate_exceptions([[b.to_execution_exception, [a0]]])
    end

    def test_the_propagation_is_robust_to_badly_specified_parents
        plan.add(parent = Roby::Task.new)
        child = parent.depends_on(Roby::Task.new)
        plan.add(task = Roby::Task.new)

        error = LocalizedError.new(child).to_execution_exception
        messages = capture_log(execution_engine, :warn) do
            result, _ = execution_engine.propagate_exceptions([[error, [task]]])
            assert_equal error, result.first.first
            assert_equal [parent, child].to_set, result.first.last.to_set
        end
        expected = ["some parents specified for Roby::LocalizedError(Roby::LocalizedError) are actually not parents of #{child}, they got filtered out", "  #{task}"] * 2
        assert_equal expected, messages
    end

    def test_garbage_collection_calls_are_propagated_first_while_quitting
        obj = Class.new do
            def stopped?; @stop end
            def stop; @stop = true end
        end.new
        flexmock(obj).should_receive(:stop).once.
            pass_thru

        task_model = Class.new(Roby::Task) do
            argument :obj

            event :start, controlable: true
            event :stop do |_|
                obj.stop
                stop_event.emit
            end
        end
        plan.add(task = task_model.new(obj: obj))
        task.start!
        plan.execution_engine.at_cycle_begin do
            if !obj.stopped?
                obj.stop
            end
        end
        plan.execution_engine.quit
        while task.running?
            plan.execution_engine.process_events
        end
    end
end

