require 'roby/test/self'
require './test/mockups/tasks'
require 'utilrb/hash/slice'

class TC_ExecutionEngine < Minitest::Test
    def setup
	super
	Roby::Log.add_logger(@finalized_tasks_recorder = FinalizedTaskRecorder.new)
    end
    def teardown
	Roby::Log.remove_logger @finalized_tasks_recorder
	super
    end

    def test_gather_propagation
	e1, e2, e3 = EventGenerator.new(true), EventGenerator.new(true), EventGenerator.new(true)
	plan.add [e1, e2, e3]

	set = engine.gather_propagation do
	    e1.call(1)
	    e1.call(4)
	    e2.emit(2)
	    e2.emit(3)
	    e3.call(5)
	    e3.emit(6)
	end
	assert_equal(
            { e1 => [1, nil, [nil, [1], nil, nil, [4], nil]],
              e2 => [3, [nil, [2], nil, nil, [3], nil], nil],
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
            plan.add_permanent(@event = Roby::EventGenerator.new(true))
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
            id = engine.add_propagation_handler(:type => :external_events) { |plan| handler.handler(plan) }

            mock.should_receive(:called).with(plan).twice

            process_events
            assert_equal(1, handler.event.history.size)

            handler.reset_event
            process_events
            assert_equal(1, handler.event.history.size)

            engine.remove_propagation_handler id
            handler.reset_event
            process_events
            assert_equal(0, handler.event.history.size)
        end
    end

    def test_add_propagation_handlers_for_propagation
        FlexMock.use do |mock|
            handler = PropagationHandlerTest.new(plan, mock)
            id = engine.add_propagation_handler(:type => :propagation) { |plan| handler.handler(plan) }

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

            engine.remove_propagation_handler id
            handler.reset_event
            process_events
            assert_equal(0, handler.event.history.size)
        end
    end

    def test_add_propagation_handlers_for_propagation_late
        FlexMock.use do |mock|
            plan.add_permanent(event = Roby::EventGenerator.new(true))
            plan.add_permanent(late_event = Roby::EventGenerator.new(true))

            index = -1
            event.on { |_| mock.event_emitted(index += 1) }
            late_event.on { |_| mock.late_event_emitted(index += 1) }


            id = engine.add_propagation_handler(:type => :propagation) do |plan|
                mock.handler_called(index += 1)
                if !event.happened?
                    event.emit
                end
            end
            late_id = engine.add_propagation_handler(:type => :propagation, :late => true) do |plan|
                mock.late_handler_called(index += 1)
                if !late_event.happened?
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
            engine.remove_propagation_handler(id)
            engine.remove_propagation_handler(late_id)
            process_events
        end
    end

    def test_add_propagation_handlers_accepts_method_object
        FlexMock.use do |mock|
            handler = PropagationHandlerTest.new(plan, mock)
            id = engine.add_propagation_handler(:type => :external_events, &handler.method(:handler))

            mock.should_receive(:called).with(plan).twice
            process_events
            process_events
            engine.remove_propagation_handler id
            process_events

            assert_equal(2, handler.event.history.size)
        end
    end

    def test_add_propagation_handler_validates_arity
        # Validate the arity
        assert_raises(ArgumentError) do
            engine.add_propagation_handler { |plan, failure| mock.called(plan) }
        end

        process_events
    end

    def test_propagation_handlers_raises_on_error
        FlexMock.use do |mock|
            engine.add_propagation_handler do |plan|
                mock.called
                raise SpecificException
            end
            mock.should_receive(:called).once
            assert_raises(SpecificException) { process_events }
        end
    end

    def test_propagation_handlers_disabled_on_error
        Roby.logger.level = Logger::FATAL
        FlexMock.use do |mock|
            engine.add_propagation_handler :on_error => :disable do |plan|
                mock.called
                raise
            end
            mock.should_receive(:called).once
            process_events
            process_events
        end
    end

    def test_propagation_handlers_ignore_on_error
        FlexMock.use do |mock|
            engine.add_propagation_handler :on_error => :ignore do |plan|
                mock.called
                raise
            end
            mock.should_receive(:called).twice
            process_events
            process_events
        end
    end

    def test_prepare_propagation
	g1, g2 = EventGenerator.new(true), EventGenerator.new(true)
	ev = Event.new(g2, 0, nil)

	step = [nil, [1], nil, nil, [4], nil]
	source_events, source_generators, context = engine.prepare_propagation(nil, false, step)
	assert_equal(ValueSet.new, source_events)
	assert_equal(ValueSet.new, source_generators)
	assert_equal([1, 4], context)

	step = [nil, [], nil, nil, [4], nil]
	source_events, source_generators, context = engine.prepare_propagation(nil, false, step)
	assert_equal(ValueSet.new, source_events)
	assert_equal(ValueSet.new, source_generators)
	assert_equal([4], context)

	step = [g1, [], nil, ev, [], nil]
	source_events, source_generators, context = engine.prepare_propagation(nil, false, step)
	assert_equal([g1, g2].to_value_set, source_generators)
	assert_equal([ev].to_value_set, source_events)
	assert_equal(nil, context)

	step = [g2, [], nil, ev, [], nil]
	source_events, source_generators, context = engine.prepare_propagation(nil, false, step)
	assert_equal([g2].to_value_set, source_generators)
	assert_equal([ev].to_value_set, source_events)
	assert_equal(nil, context)
    end

    def test_precedence_graph
	e1, e2 = EventGenerator.new(true), EventGenerator.new(true)
	engine.event_ordering << :bla
	plan.add e1
	assert(engine.event_ordering.empty?)
	plan.add e2
	
	engine.event_ordering << :bla
	task = Roby::Task.new
	plan.add(task)
	assert(engine.event_ordering.empty?)
	assert(EventStructure::Precedence.linked?(task.event(:start), task.event(:updated_data)))

	engine.event_ordering << :bla
	e1.signals e2
	assert(EventStructure::Precedence.linked?(e1, e2))
	assert(engine.event_ordering.empty?)

	engine.event_ordering << :bla
	e1.remove_signal e2
	assert(engine.event_ordering.empty?)
	assert(!EventStructure::Precedence.linked?(e1, e2))
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
	pending << [e1, [0, nil, []]] << [e2, [1, [], nil]]
	assert_equal(e2, engine.next_event(pending).first)
        pending.clear
	pending << [e1, [1, [], nil]] << [e2, [0, [], nil]]
	assert_equal(e2, engine.next_event(pending).first)

        # If there *is* a precedence relation, we must follow it
        pending.clear
	pending << [e1, [0, [], nil]] << [e2, [1, [], nil]]

	e1.add_precedence e2
	assert_equal(e1, engine.next_event(pending).first)
	e1.remove_precedence e2
	e2.add_precedence e1
	assert_equal(e2, engine.next_event(pending).first)
    end

    def test_delay
	FlexMock.use(Time) do |time_proxy|
	    current_time = Time.now + 5
	    time_proxy.should_receive(:now).and_return { current_time }

	    plan.add_mission(t = Tasks::Simple.new)
	    e = EventGenerator.new(true)
	    t.event(:start).signals e, :delay => 0.1
	    engine.once { t.start! }
	    process_events
	    assert(!e.happened?)
	    current_time += 0.1
	    process_events
	    assert(e.happened?)
	end
    end

    def test_delay_with_unreachability
	FlexMock.use(Time) do |time_proxy|
	    current_time = Time.now + 5
	    time_proxy.should_receive(:now).and_return { current_time }

	    plan.add_permanent(source = Tasks::Simple.new)
	    plan.add_permanent(sink0 = Tasks::Simple.new)
	    plan.add_permanent(sink1 = Tasks::Simple.new)
	    source.start_event.signals sink0.start_event, :delay => 0.1
	    source.start_event.signals sink1.start_event, :delay => 0.1
	    engine.once { source.start! }
	    process_events
	    assert(!sink0.start_event.happened?)
	    assert(!sink1.start_event.happened?)

            plan.remove_object(sink0)
            sink1.failed_to_start!("test")
            assert(sink0.start_event.unreachable?)
            assert(sink1.start_event.unreachable?)
            assert(! engine.delayed_events.
                   find { |_, _, _, target, _| target == sink0.start_event })
            assert(! engine.delayed_events.
                   find { |_, _, _, target, _| target == sink1.start_event })

	    current_time += 0.1
            # Avoid unnecessary error messages
            plan.unmark_permanent(sink0)
            plan.unmark_permanent(sink1)
	end
    end

    def test_duplicate_signals
	plan.add_mission(t = Tasks::Simple.new)
	
	FlexMock.use do |mock|
	    t.on(:start)   { |event| t.emit(:success, *event.context) }
	    t.on(:start)   { |event| t.emit(:success, *event.context) }

	    t.on(:success) { |event| mock.success(event.context) }
	    t.on(:stop)    { |event| mock.stop(event.context) }
	    mock.should_receive(:success).with([42, 42]).once.ordered
	    mock.should_receive(:stop).with([42, 42]).once.ordered
	    t.start!(42)
	end
    end

    def test_default_task_ordering
	a = Tasks::Simple.new_submodel do
	    event :intermediate
	end.new(:id => 'a')

	plan.add_mission(a)
	a.depends_on(b = Tasks::Simple.new(:id => 'b'))

	b.forward_to(:success, a, :intermediate)
	b.forward_to(:success, a, :success)

	FlexMock.use do |mock|
            b.on(:success) { |ev| mock.child_success }
	    a.on(:intermediate) { |ev| mock.parent_intermediate }
	    a.on(:success) { |ev| mock.parent_success }
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
	    forward :child_success => :child_stop
	end.new(:id => 'a')

	plan.add_mission(a)
	a.depends_on(b = Tasks::Simple.new(:id => 'b'))

	b.forward_to(:success, a, :child_success)
	b.forward_to(:stop, a, :child_stop)

	FlexMock.use do |mock|
	    a.on(:child_stop) { |ev| mock.stopped }
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

	    seeds = engine.gather_propagation do
		forward.call(24)
		signal.call(42)
	    end
	    mock.should_receive(:command_called).with([42]).once.ordered
	    mock.should_receive(:handler_called).with([42, 24]).once.ordered
	    engine.event_propagation_phase(seeds)
	end
    end

    module LogEventGathering
	class << self
	    attr_accessor :mockup
	    def handle(name, obj)
		mockup.send(name, obj, obj.engine.propagation_sources) if mockup
	    end
	end

	def signalling(event, to)
	    super if defined? super
	    LogEventGathering.handle(:signalling, self)
	end
	def forwarding(event, to)
	    super if defined? super
	    LogEventGathering.handle(:forwarding, self)
	end
	def emitting(context)
	    super if defined? super
	    LogEventGathering.handle(:emitting, self)
	end
	def calling(context)
	    super if defined? super
	    LogEventGathering.handle(:calling, self)
	end
    end
    EventGenerator.include LogEventGathering

    def test_log_events
	FlexMock.use do |mock|
	    LogEventGathering.mockup = mock
	    dst = EventGenerator.new { }
	    src = EventGenerator.new { dst.call }
	    plan.add [src, dst]

	    mock.should_receive(:signalling).never
	    mock.should_receive(:forwarding).never
	    mock.should_receive(:calling).with(src, [].to_value_set).once
	    mock.should_receive(:calling).with(dst, [src].to_value_set).once
	    src.call
	end

    ensure 
	LogEventGathering.mockup = nil
    end

    def test_add_framework_errors
	# Shut up the logger in this test
	Roby.logger.level = Logger::FATAL
	exception = begin; raise RuntimeError
		    rescue; $!
		    end

	Roby.app.abort_on_application_exception = false
	engine.add_framework_error(exception, :exceptions)

	Roby.app.abort_on_application_exception = true
	assert_raises(RuntimeError) { engine.add_framework_error(exception, :exceptions) }
    end

    def test_event_loop
        plan.add_mission(start_node = EmptyTask.new)
        next_event = [ start_node, :start ]
        plan.add_mission(if_node    = ChoiceTask.new)
        start_node.on(:stop) { |ev| next_event = [if_node, :start] }
	if_node.on(:stop) { |ev| }
            
        engine.add_propagation_handler(:type => :external_events) do |plan|
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
	# Check that every(cycle_length) works fine
	engine.run

	samples = []
	id = engine.every(0.1) do
	    samples << engine.cycle_start
	end
	sleep(1)
	engine.remove_periodic_handler(id)
	size = samples.size
	assert(size > 2, "expected 2 samples, got #{samples.map { |t| t.to_hms }.join(", ")}")

	samples.each_cons(2) do |a, b|
	    assert_in_delta(0.1, b - a, 0.001)
	end

	# Check that no samples have been added after the 'remove_periodic_handler'
	assert_equal(size, samples.size)
    end

    def test_once_blocks_are_called_by_proces_events
	FlexMock.use do |mock|
	    engine.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	end
    end
    def test_once_blocks_are_called_only_once
	FlexMock.use do |mock|
	    engine.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	    process_events
	end
    end

    def test_failing_once
	Roby.logger.level = Logger::FATAL + 1
	Roby.app.abort_on_exception = true
	engine.run

	FlexMock.use do |mock|
	    engine.once { mock.called; raise }
	    mock.should_receive(:called).once

	    assert_raises(ExecutionQuitError) do
		engine.wait_one_cycle
		engine.join
	    end
	end
    end

    class SpecificException < RuntimeError; end
    def test_unhandled_event_command_exception
	Roby.app.abort_on_exception = true

	# Test that the event is not pending if the command raises
	model = Tasks::Simple.new_submodel do
	    event :start do |context|
		raise SpecificException, "bla"
            end
	end
	plan.add_permanent(t = model.new(:id => 1))

	assert_original_error(SpecificException, CommandFailed) { t.start! }
	assert(!t.event(:start).pending?)

	# Check that the propagation is pruned if the command raises
	t = nil
	FlexMock.use do |mock|
	    t = Tasks::Simple.new_submodel do
		event :start do |context|
		    mock.command_called
		    raise SpecificException, "bla"
		    emit :start
                end
		on(:start) { |ev| mock.handler_called }
	    end.new(:id => 2)
	    plan.add_permanent(t)

	    mock.should_receive(:command_called).once
	    mock.should_receive(:handler_called).never

	    engine.once { t.start!(nil) }
	    assert_original_error(SpecificException, CommandFailed) { process_events }
	    assert(!t.event(:start).pending)
            assert(t.failed_to_start?)
	end

	# Check that the task gets garbage collected in the process
	assert(! plan.include?(t))
    end

    def test_unhandled_event_handler_exception
        # To stop the error message
	Roby.logger.level = Logger::FATAL

	model = Tasks::Simple.new_submodel do
	    on :start do |event|
		raise SpecificException, "bla"
            end
	end

        plan.add_permanent(t = model.new)
        engine.run

        assert_event_emission(t.failed_event) do
            t.start!
        end

	# Check that the task has been garbage collected in the process
	assert(! plan.include?(t))
	assert(t.failed?)
    end


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
        t0, t1, t2 = prepare_plan :add => 3
        errors = Hash[LocalizedError.new(t0).to_execution_exception => [t1]]
	Plan.structure_checks << lambda do |plan|
            return errors
        end
        engine = flexmock(self.engine)
        engine.should_receive(:propagate_exceptions).with([]).and_return([])
        engine.should_receive(:propagate_exceptions).with(errors).once
        engine.should_receive(:remove_inhibited_exceptions).with(errors).
            and_return([[LocalizedError.new(t0), [t2]]])
        assert_equal [[LocalizedError.new(t0), [t2]]],
            engine.compute_fatal_errors(Hash[:start => Time.now], [])
    end

    def test_at_cycle_end
	# Shut up the logger in this test
	Roby.logger.level = Logger::FATAL
        Roby.app.abort_on_application_exception = false

        FlexMock.use do |mock|
            mock.should_receive(:before_error).at_least.once
            mock.should_receive(:after_error).never
            mock.should_receive(:called).at_least.once

            engine.at_cycle_end do
		mock.before_error
		raise
		mock.after_error
            end

            engine.at_cycle_end do
		mock.called
		unless engine.quitting?
		    engine.quit
		end
            end
            engine.run
            engine.join
        end
    end

    def test_inside_outside_control
	# First, no control thread
	assert(engine.inside_control?)
	assert(engine.outside_control?)

	# Add a fake control thread
	begin
	    engine.thread = Thread.main
	    assert(engine.inside_control?)
	    assert(!engine.outside_control?)

	    t = Thread.new do
		assert(!engine.inside_control?)
		assert(engine.outside_control?)
	    end
	    t.value
	ensure
	    engine.thread = nil
	end

	# .. and test with the real one
	engine.run
	engine.execute do
	    assert(engine.inside_control?)
	    assert(!engine.outside_control?)
	end
	assert(!engine.inside_control?)
	assert(engine.outside_control?)
    end

    def test_execute
	# Set a fake control thread
	engine.thread = Thread.main

	FlexMock.use do |mock|
	    mock.should_receive(:thread_before).once.ordered
	    mock.should_receive(:main_before).once.ordered
	    mock.should_receive(:execute).once.ordered.with(Thread.current).and_return(42)
	    mock.should_receive(:main_after).once.ordered(:finish)
	    mock.should_receive(:thread_after).once.ordered(:finish)

	    returned_value = nil
	    t = Thread.new do
		mock.thread_before
		returned_value = engine.execute do
		    mock.execute(Thread.current)
		end
		mock.thread_after
	    end

	    # Wait for the thread to block
	    while !t.stop?; sleep(0.1) end
	    mock.main_before
	    assert(t.alive?)
            # We use engine.process_events as we are making the engine
            # believe that it is running while it is not
	    engine.process_events
	    mock.main_after
	    t.join

	    assert_equal(42, returned_value)
	end

    ensure
	engine.thread = nil
    end

    def test_execute_error
	assert(!engine.thread)
	# Set a fake control thread
	engine.thread = Thread.main
	assert(!engine.quitting?)

	returned_value = nil
	t = Thread.new do
	    returned_value = begin
				 engine.execute do
				     raise ArgumentError
				 end
			     rescue ArgumentError => e
				 e
			     end
	end

	# Wait for the thread to block
	while !t.stop?; sleep(0.1) end
        assert(t.alive?)
        # We use engine.process_events as we are making the engine
        # believe that it is running while it is not
	engine.process_events
	t.join

	assert_kind_of(ArgumentError, returned_value)
	assert(!engine.quitting?)

    ensure
	engine.thread = nil
    end
    
    def test_wait_until
	# Set a fake control thread
	engine.thread = Thread.main

	plan.add_permanent(task = Tasks::Simple.new)
	t = Thread.new do
	    engine.wait_until(task.event(:start)) do
		task.start!
	    end
	end

	while !t.stop?; sleep(0.1) end
        # We use engine.process_events as we are making the engine
        # believe that it is running while it is not
	engine.process_events
	t.value

    ensure
	engine.thread = nil
    end
 
    def test_wait_until_unreachable
	# Set a fake control thread
	engine.thread = Thread.main

	plan.add_permanent(task = Tasks::Simple.new)
	t = Thread.new do
	    begin
		engine.wait_until(task.event(:success)) do
		    task.start!
                    task.stop!
		end
	    rescue Exception => e
		e
	    end
	end

        # Wait for #wait_until, in the thread, to wait for the main thread
	while !t.stop?; sleep(0.1) end
        # And process the events
        with_log_level(Roby, Logger::FATAL) do
            # We use engine.process_events as we are making the engine
            # believe that it is running while it is not
            engine.process_events
        end

	result = t.value
	assert_kind_of(UnreachableEvent, result)
	assert_equal(task.event(:success), result.failed_generator)

    ensure
	engine.thread = nil
    end

    class CaptureLastStats
	attr_reader :last_stats
	def splat?; true end
        def logs_message?(m); m == :cycle_end end
        def close; end
	def cycle_end(time, stats)
	    @last_stats = stats
	end
    end
    
    def test_stats
        require 'roby/log'
	engine.run

	capture = CaptureLastStats.new
	Roby::Log.add_logger capture

	time_events = [:real_start, :events, :structure_check, :exception_propagation, :exception_fatal, :garbage_collect, :application_errors, :ruby_gc, :sleep, :end]
	10.times do
	    engine.wait_one_cycle
	    next unless capture.last_stats

	    Roby.synchronize do
		timepoints = capture.last_stats.slice(*time_events)
		assert(timepoints.all? { |name, d| d > 0 })

		sorted_by_time = timepoints.sort_by { |name, d| d }
		sorted_by_name = timepoints.sort_by { |name, d| time_events.index(name) }
		sorted_by_time.each_with_index do |(name, d), i|
		    assert(sorted_by_name[i][1] == d)
		end
	    end
	end

    ensure
	Roby::Log.remove_logger capture if capture
    end

    def clear_finalized
        Roby::Log.flush
        @finalized_tasks_recorder.clear
    end
    # Returns the RemoteID for tasks that have been finalized since the last
    # call to #clear_finalized.
    def finalized_tasks; @finalized_tasks_recorder.tasks end
    # Returns the RemoteID for events that have been finalized since the last
    # call to #clear_finalized.
    def finalized_events; @finalized_tasks_recorder.events end
    class FinalizedTaskRecorder
	attribute(:tasks) { Array.new }
	attribute(:events) { Array.new }
        def logs_message?(m); m == :finalized_task || m == :finalized_event end
	def finalized_task(time, plan, task)
	    tasks << task
	end
	def finalized_event(time, plan, event)
	    events << event unless event.respond_to?(:task)
	end
	def clear
	    tasks.clear
	    events.clear
	end
        def close; end
	def splat?; true end
    end

    def assert_finalizes(plan, finalized, unneeded = nil)
	finalized = finalized.map { |obj| obj.remote_id }
	clear_finalized

	yield if block_given?

	engine.garbage_collect
	engine.garbage_collect
        if unneeded
            assert_equal(unneeded.to_set, plan.unneeded_tasks.to_set)
        end

        # !!! We are actually relying on the logging queue for this to work.
        # make sure it is empty before testing anything
        Roby::Log.flush

	assert_equal(finalized.to_set, (finalized_tasks.to_set | finalized_events.to_set) )
	assert(! finalized.any? { |t| plan.include?(t) })
    end

    def test_garbage_collect_tasks
	klass = Task.new_submodel do
	    attr_accessor :delays

	    event(:start, :command => true)
	    event(:stop) do |context|
		if delays
		    return
		else
		    emit(:stop)
		end
            end
	end

        (m1, m2, m3), (t1, t2, t3, t4, t5, p1) =
            prepare_plan :missions => 3, :add => 6, :model => klass
        dependency_chain m1, t1, t2
        dependency_chain m2, t1
        dependency_chain m3, t2
        m3.planned_by p1
        p1.depends_on t3
	t4.depends_on t5

	plan.add_permanent(t4)

	assert_finalizes(plan, [])
	assert_finalizes(plan, [m1]) { plan.unmark_mission(m1) }
	assert_finalizes(plan, [m2, t1]) do
	    m2.start!
	    plan.unmark_mission(m2)
	end

	assert_finalizes(plan, [], [m3, p1, t3, t2]) do
	    m3.delays = true
	    m3.start!
	    plan.unmark_mission(m3)
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

	plan.add_mission(t1)
	t1.start!
	assert_finalizes(plan, []) do
	    engine.garbage_collect([t1])
	end
	assert(t1.event(:stop).pending?)

	assert_finalizes(plan, [t1, t2]) do
	    # This stops the mission, which will be automatically discarded
	    t1.event(:stop).emit(nil)
	end
    end

    def test_gc_ignores_incoming_events
	Roby::Plan.logger.level = Logger::WARN
	a, b = prepare_plan :discover => 2, :model => Tasks::Simple
	a.signals(:stop, b, :start)
	a.start!

	process_events
	process_events
	assert(!a.plan)
	assert(!b.plan)
	assert(!b.event(:start).happened?)
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
		event :start, :command => true
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
		
	    engine.garbage_collect
	    process_events

	    assert(!plan.include?(t1))
	    assert(!plan.include?(t2))
	    running_tasks.each do |t|
		assert(t.finishing?)
		t.emit(:stop)
	    end

	    engine.garbage_collect
	    running_tasks.each do |t|
		assert(!plan.include?(t))
	    end
	end

    ensure
	running_task.emit(:stop) if running_task && !running_task.finished?
    end

    def test_garbage_collect_events
	t  = Tasks::Simple.new
	e1 = EventGenerator.new(true)

	plan.add_mission(t)
	plan.add(e1)
	assert_equal([e1], plan.unneeded_events.to_a)
	t.event(:start).signals e1
	assert_equal([], plan.unneeded_events.to_a)

	e2 = EventGenerator.new(true)
	plan.add(e2)
	assert_equal([e2], plan.unneeded_events.to_a)
	e1.forward_to e2
	assert_equal([], plan.unneeded_events.to_a)

	plan.remove_object(t)
	assert_equal([e1, e2].to_value_set, plan.unneeded_events)

        plan.add_permanent(e1)
	assert_equal([], plan.unneeded_events.to_a)
        plan.unmark_permanent(e1)
	assert_equal([e1, e2].to_value_set, plan.unneeded_events)
        plan.add_permanent(e2)
	assert_equal([], plan.unneeded_events.to_a)
        plan.unmark_permanent(e2)
	assert_equal([e1, e2].to_value_set, plan.unneeded_events)
    end

    def test_garbage_collect_weak_relations
	engine.run

	engine.execute do
	    planning, planned, influencing = prepare_plan :discover => 3, :model => Tasks::Simple

	    planned.planned_by planning
	    influencing.depends_on planned
	    planning.influenced_by influencing

	    planned.start!
	    planning.start!
	    influencing.start!
	end

	engine.wait_one_cycle
	engine.wait_one_cycle
	engine.wait_one_cycle

	assert(plan.known_tasks.empty?)
    end

    def test_mission_failed
	model = Tasks::Simple.new_submodel do
	    event :specialized_failure, :command => true
	    forward :specialized_failure => :failed
	end

	task = prepare_plan :missions => 1, :model => model
	task.start!
        
        inhibit_fatal_messages do
            assert_raises(Roby::MissionFailedError) { task.specialized_failure! }
        end
	
	error = Roby::Plan.check_failed_missions(plan).first.exception
	assert_kind_of(Roby::MissionFailedError, error)
	assert_equal(task.event(:specialized_failure).last, error.failure_point)
        Roby.format_exception error

	# Makes teardown happy
	plan.remove_object(task)
    end

    def test_check_relations_structure
        r_t = TaskStructure.relation :TestRT
        r_e = EventStructure.relation :TestRE

        FlexMock.use do |mock|
            r_t.singleton_class.class_eval do
                define_method :check_structure do |plan|
                    mock.checked_task_relation(plan)
                    []
                end
            end
            r_e.singleton_class.class_eval do
                define_method :check_structure do |plan|
                    mock.checked_event_relation(plan)
                    []
                end
            end

            plan = Plan.new
            assert plan.relations.include?(r_t)
            assert plan.relations.include?(r_e)

            mock.should_receive(:checked_task_relation).with(plan).once
            mock.should_receive(:checked_event_relation).with(plan).once
            assert_equal(Hash.new, plan.check_structure)
        end
    ensure
        TaskStructure.remove_relation r_t if r_t
        EventStructure.remove_relation r_e if r_e
    end

    def test_forward_signal_ordering
        100.times do
            stop_called = false
            source = Tasks::Simple.new(:id => 'source')
            target = Tasks::Simple.new_submodel do
                event :start do |context|
                    if !stop_called
                        raise ArgumentError, "ordering failed"
                    end
                    emit :start
                end
            end.new(:id => 'target')
            plan.add(source)
            plan.add(target)

            source.signals :success, target, :start
            source.on :stop do |ev|
                stop_called = true
            end
            source.start!
            source.emit :success
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
        engine.delayed(5) { recorder.triggered(Time.now) }
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
            engine.add_error LocalizedError.new(task)
        end
        process_events
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

        t1, t2 = prepare_plan :add => 2
        t0 = make_task_with_handler(SpecializedError, mock)
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))
        mock.should_receive(:handler).once.
            with(on { |e| e.trace == [t2, t1, t0] && e.origin == t2 }, t0)
        assert_equal([], engine.propagate_exceptions([error]))
    end

    def test_it_ignores_handlers_that_do_not_match_the_filter
        t1, t2 = prepare_plan :add => 2
        t0 = make_task_with_handler(CodeError, nil)
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))

        remaining = engine.propagate_exceptions([error])
        assert_equal 1, remaining.size
        remaining_error, affected_tasks = remaining.first
        assert_equal error, remaining_error
        assert_equal error.trace.to_set, affected_tasks.to_set
    end

    def test_it_does_not_call_global_handlers_if_the_exception_is_handled_by_a_task
        mock = flexmock

        t1, t2 = prepare_plan :add => 3
        t0 = make_task_with_handler(SpecializedError, mock)
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))
        plan.on_exception(SpecializedError) do |p, e|
            mock.handler(e, p)
        end
        mock.should_receive(:handler).with(error, t0).once
        mock.should_receive(:handler).with(error, plan).never
        assert_equal([], engine.propagate_exceptions([error]))
    end

    def test_it_uses_global_handlers_to_filter_exceptions_that_have_not_been_handled_by_a_task
        mock = flexmock

        t0, t1, t2 = prepare_plan :add => 3
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))
        plan.on_exception(SpecializedError) do |p, e|
            mock.handler(e, p)
        end
        mock.should_receive(:handler).with(error, plan).once
        assert_equal([], engine.propagate_exceptions([error]))
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

	mock = flexmock

        t1, t2, t3 = prepare_plan :add => 3
        t0 = Task.new_submodel do 
            on_exception(Roby::CodeError) do |exception|
                mock.handler(exception, exception.trace, self)
            end
        end.new
        dependency_chain t0, t1, t2
        dependency_chain t3, t2

        mock.should_receive(:handler).
            with(ExecutionException, [t2, t1, t0], t0).once
        flexmock(engine).should_receive(:handled_exception).
            with(on { |e| e.trace == [t2, t1, t0] }, t0)

        error = ExecutionException.new(CodeError.new(nil, t2))
        fatal = engine.propagate_exceptions([error])
        assert_equal 1, fatal.size

        exception, affected_tasks = fatal.first
        assert_equal [t2, t3], exception.trace
        assert_equal [t3], affected_tasks
    end

    def test_propagate_exceptions_diamond_propagation
        mock = flexmock

        t11, t12, t2 = prepare_plan :add => 3

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
        assert_equal([], engine.propagate_exceptions([error]))
    end

    def test_event_propagation_with_exception
	ev = EventGenerator.new do |context|
	    raise RuntimeError
	    ev.emit(context)
	end
	plan.add(ev)
	assert_original_error(RuntimeError, CommandFailed) { ev.call(nil) }
	assert(!ev.happened?)

	# Check that the event is emitted anyway
	ev = EventGenerator.new do |context|
	    ev.emit(context)
	    raise RuntimeError
	end
	plan.add(ev)
	assert_original_error(RuntimeError, CommandFailed) { ev.call(nil) }
	assert(ev.happened?)

	# Check signalling
	ev = EventGenerator.new do |context|
	    ev.emit(context)
	    raise RuntimeError
	end
	plan.add(ev)
	ev2 = EventGenerator.new(true)
	ev.signals ev2

	assert_original_error(RuntimeError, CommandFailed) { ev.call(nil) }
	assert(ev.happened?)
	assert(ev2.happened?)

	# Check event handlers
	FlexMock.use do |mock|
	    ev = EventGenerator.new(true)
	    plan.add(ev)
	    ev.on { |ev| mock.handler ; raise RuntimeError }
	    ev.on { |ev| mock.handler }
	    mock.should_receive(:handler).twice
	    assert_original_error(RuntimeError, EventHandlerError) { ev.call }
	end
    end

    # Tests exception handling mechanism during event propagation
    def test_task_propagation_with_exception
	Roby.app.abort_on_exception = true
	Roby::ExecutionEngine.logger.level = Logger::FATAL + 1

	task = Tasks::Simple.new_submodel do
	    event :start do |context|
		emit(:start)
		raise RuntimeError, "failed"
            end
	end.new

	FlexMock.use do |mock|
	    parent = Tasks::Simple.new_submodel do
		on_exception ChildFailedError do |exception|
		    mock.exception
		    task.pass_exception
		end
	    end.new
	    mock.should_receive(:exception).once

	    parent.depends_on task
	    plan.add_permanent(parent)
            
	    engine.once { parent.start!; task.start! }

	    mock.should_receive(:other_once_handler).once
	    mock.should_receive(:other_event_processing).once
	    engine.once { mock.other_once_handler }
	    engine.add_propagation_handler(:type => :external_events) { |plan| mock.other_event_processing }

	    begin
		process_events
		flunk("should have raised")
	    rescue Roby::ChildFailedError
	    end
	end
	assert(task.event(:start).happened?)
    end

    def test_exception_argument_count_validation
        assert_raises(ArgumentError) do
            Task.new_submodel.on_exception(RuntimeError) do |a, b|
            end
        end
        Task.new_submodel.on_exception(RuntimeError) do |_|
        end

        assert_raises(ArgumentError) do |a, b|
            plan.on_exception(RuntimeError) do |_|
            end
        end
        plan.on_exception(RuntimeError) do |_, _|
        end
    end

    def test_error_handling_relation(error_event = :failed)
	task_model = Tasks::Simple.new_submodel do
	    event :blocked
	    forward :blocked => :failed
	end

	parent, (child, *repair_tasks) = prepare_plan :permanent => 1, :add => 3, :model => task_model
	parent.depends_on child
	child.event(:failed).handle_with repair_tasks[0]

	parent.start!
	child.start!
	child.emit error_event

	exceptions = plan.check_structure
        assert engine.remove_inhibited_exceptions(exceptions).empty?
	assert_equal([], engine.propagate_exceptions(exceptions))

        repairs = child.find_all_matching_repair_tasks(child.terminal_event)
        assert_equal 1, repairs.size
        repair_task = repairs.first

	Roby.app.abort_on_exception = false
        # Verify that both the repair and root tasks are not garbage collected
	process_events
	assert(repair_task.running?)

	# Make the "repair task" finish, but do not repair the plan.
	# propagate_exceptions must not add a new repair
        inhibit_fatal_messages do
            assert_raises(ChildFailedError) do
                repair_task.success!
            end
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
                new(:id => 10)
            end
        end
        task = prepare_plan :add => 1, :model => Tasks::Simple
        child = task.failed_event.handle_with(model)
        assert_kind_of model, child
        assert_equal 10, child.arguments[:id]
    end

    def test_mission_exceptions
	mission = prepare_plan :missions => 1, :model => Tasks::Simple
	mission.start!
        inhibit_fatal_messages do
            assert_raises(MissionFailedError) { mission.emit(:failed) }
        end

	exceptions = plan.check_structure
	assert_equal(1, exceptions.size)
	assert_kind_of(Roby::MissionFailedError, exceptions.to_a[0][0].exception, exceptions)

	# Discard the mission so that the test teardown does not complain
	plan.unmark_mission(mission)
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

    def test_fatal_exception_handling
        Roby.logger.level = Logger::FATAL
        def engine.fatal_exception(error, tasks)
            super if defined? super
            tasks.each { |t| @fatal << t }
        end
        def engine.fatal; @fatal ||= [] end
        engine.fatal

        task_model = Tasks::Simple.new_submodel do
            event :intermediate do |context|
                emit :intermediate
            end
        end
        
        t1, t2, t3 = prepare_plan :add => 3, :model => task_model
        t1.depends_on t2
        t2.depends_on t3, :failure => [:intermediate]

        plan.add_permanent(t1)
        t1.start!
        t2.start!
        plan.add_permanent(t3)
        t3.start!

        engine.run
        messages = gather_log_messages :fatal_exception do
            assert_event_emission(t3.intermediate_event) do
                assert(engine.fatal.empty?)
                t3.intermediate!
            end

            engine.execute do
                assert_equal [t3, t2, t1], engine.fatal
            end
        end
        assert_equal(1, messages.size)
        name, time, (error, tasks) = *messages.first
        assert_equal('fatal_exception', name)
        assert_equal([t1.remote_id, t2.remote_id, t3.remote_id].to_set, tasks.to_set)
    end

    def test_permanent_task_errors_are_nonfatal
        task = prepare_plan :permanent => 1, :model => Tasks::Simple

        mock = flexmock
        mock.should_receive(:called).once.with(false)

        plan.on_exception(PermanentTaskError) do |plan, error|
            plan.unmark_permanent(error.task)
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
        a0, a1 = prepare_plan :add => 2, :model => task_model
        plan.add(b = Roby::Task.new)
        a0.depends_on b
        a1.depends_on b
        mock.should_receive(:called).with(a0).once
        mock.should_receive(:called).with(a1).never
        engine.propagate_exceptions([[b.to_execution_exception, [a0]]])
    end

    def test_the_propagation_is_robust_to_badly_specified_parents
        plan.add(parent = Roby::Task.new)
        child = parent.depends_on(Roby::Task.new)
        plan.add(task = Roby::Task.new)

        error = LocalizedError.new(child).to_execution_exception
        result = inhibit_fatal_messages do
            engine.propagate_exceptions([[error, [task]]])
        end
        assert_equal error, result.first.first
        assert_equal [parent, child].to_set, result.first.last.to_set
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
                emit :stop
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

