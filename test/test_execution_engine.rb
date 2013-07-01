$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/tasks/simple'
require 'roby/test/tasks/empty_task'
require 'mockups/tasks'
require 'flexmock'
require 'utilrb/hash/slice'
require 'roby/log'

class TC_ExecutionEngine < Test::Unit::TestCase
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

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

        assert_nothing_raised { process_events }
    end

    def test_propagation_handlers_raises_on_error
        FlexMock.use do |mock|
            id = engine.add_propagation_handler do |plan|
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
            id = engine.add_propagation_handler :on_error => :disable do |plan|
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
            id = engine.add_propagation_handler :on_error => :ignore do |plan|
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

    def test_diamond_structure
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
	assert_nothing_raised { engine.add_framework_error(exception, :exceptions) }

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

    def test_check_structure
	Roby.logger.level = Logger::FATAL
	Roby.app.abort_on_exception = false

	# Check on a single, non-running task
	plan.add_mission(t = Tasks::Simple.new)
	apply_check_structure { LocalizedError.new(t) }
	assert(! plan.include?(t))

	# Make sure that a task which has been repaired will not be killed
	plan.add_mission(t = Tasks::Simple.new)
	did_once = false
	apply_check_structure do
	    unless did_once
		did_once = true
		LocalizedError.new(t)
	    end
	end
	assert(plan.include?(t))

	# Check that whole task trees are killed
	t0, t1, t2, t3 = prepare_plan :discover => 4
	t0.depends_on t2
	t1.depends_on t2
	t2.depends_on t3

	plan.add_mission(t0)
	plan.add_mission(t1)
	FlexMock.use do |mock|
	    mock.should_receive(:checking).twice
	    apply_check_structure do
		mock.checking
		LocalizedError.new(t2)
	    end
	end
	assert(!plan.include?(t0))
	assert(!plan.include?(t1))
	assert(!plan.include?(t2))
	process_events
	assert(!plan.include?(t3))

	# Check that we can kill selectively by returning a hash
	t0, t1, t2 = prepare_plan :discover => 3
	t0.depends_on t2
	t1.depends_on t2
	plan.add_mission(t0)
	plan.add_mission(t1)
	apply_check_structure { { LocalizedError.new(t2) => t0 } }
	assert(!plan.include?(t0))
	assert(plan.include?(t1))
	assert(plan.include?(t2))
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
	    process_events
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
	process_events
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
	process_events
	assert_nothing_raised { t.value }

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
            process_events
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

    def assert_finalizes(plan, unneeded, finalized = nil)
	finalized ||= unneeded
	finalized = finalized.map { |obj| obj.remote_id }
	clear_finalized

	yield if block_given?

	assert_equal(unneeded.to_set, plan.unneeded_tasks.to_set)
	engine.garbage_collect
        process_events
	engine.garbage_collect

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

	t1, t2, t3, t4, t5, t6, t7, t8, p1 = (1..9).map { |i| klass.new(:id => i) }
	t1.depends_on t3
	t2.depends_on t3
	t3.depends_on t4
	t5.depends_on t4
	t5.planned_by p1
	p1.depends_on t6

	t7.depends_on t8

	[t1, t2, t5].each { |t| plan.add_mission(t) }
	plan.add_permanent(t7)

	assert_finalizes(plan, [])
	assert_finalizes(plan, [t1]) { plan.unmark_mission(t1) }
	assert_finalizes(plan, [t2, t3]) do
	    t2.start!(nil)
	    plan.unmark_mission(t2)
	end

	assert_finalizes(plan, [t5, t4, p1, t6], []) do
	    t5.delays = true
	    t5.start!(nil)
	    plan.unmark_mission(t5)
	end
	assert(t5.event(:stop).pending?)
	assert_finalizes(plan, [t5, t4, p1, t6]) do
	    t5.event(:stop).emit(nil)
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

	assert_finalizes(plan, [t1, t2], [t1, t2]) do
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
        assert_nothing_raised do
            Roby.format_exception error
        end

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
end

