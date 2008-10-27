$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/test/tasks/simple_task'
require 'roby/test/tasks/empty_task'
require 'mockups/tasks'
require 'flexmock'
require 'utilrb/hash/slice'

class TC_ExecutionEngine < Test::Unit::TestCase
    include Roby::Test

    def setup
        super
        Roby.app.filter_backtraces = false
    end

    def test_gather_propagation
	e1, e2, e3 = EventGenerator.new(true), EventGenerator.new(true), EventGenerator.new(true)
	plan.discover [e1, e2, e3]

	set = engine.gather_propagation do
	    e1.call(1)
	    e1.call(4)
	    e2.emit(2)
	    e2.emit(3)
	    e3.call(5)
	    e3.emit(6)
	end
	assert_equal({ e1 => [nil, [nil, [1], nil, nil, [4], nil]], e2 => [[nil, [2], nil, nil, [3], nil], nil], e3 => [[nil, [6], nil], [nil, [5], nil]] }, set)
    end

    def test_propagation_handlers
        test_obj = Object.new
        def test_obj.mock_handler(plan)
            @mockup.called(plan)
        end

        FlexMock.use do |mock|
            test_obj.instance_variable_set :@mockup, mock
            id = engine.add_propagation_handler test_obj.method(:mock_handler)

            mock.should_receive(:called).with(plan).twice
            process_events
            process_events
            engine.remove_propagation_handler id
            process_events
        end

        FlexMock.use do |mock|
            test_obj.instance_variable_set :@mockup, mock
            id = engine.add_propagation_handler { |plan| mock.called(plan) }

            mock.should_receive(:called).with(plan).twice
            process_events
            process_events
            engine.remove_propagation_handler id
            process_events
        end

        assert_raises(ArgumentError) do
            engine.add_propagation_handler { |plan, failure| mock.called(plan) }
        end

        assert_nothing_raised { process_events }
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
	plan.discover e1
	assert(engine.event_ordering.empty?)
	plan.discover e2
	
	engine.event_ordering << :bla
	task = Roby::Task.new
	plan.discover(task)
	assert(engine.event_ordering.empty?)
	assert(EventStructure::Precedence.linked?(task.event(:start), task.event(:updated_data)))

	engine.event_ordering << :bla
	e1.signal e2
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
	e1, e2 = EventGenerator.new(true), EventGenerator.new(true)
	plan.discover [e1, e2]
	pending = [ [e1, [true, nil, nil, nil]], [e2, [false, nil, nil, nil]] ]
	def pending.each_key; each { |(k, v)| yield(k) } end
	def pending.delete(ev); delete_if { |(k, v)| k == ev } end

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

	    plan.add_mission(t = SimpleTask.new)
	    e = EventGenerator.new(true)
	    t.event(:start).on e, :delay => 0.1
	    engine.once { t.start! }
	    process_events
	    assert(!e.happened?)
	    current_time += 0.1
	    process_events
	    assert(e.happened?)
	end
    end

    def test_duplicate_signals
	plan.add_mission(t = SimpleTask.new)
	
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
    def test_diamond_structure
	a = Class.new(SimpleTask) do
	    event :child_success
	    event :child_stop
	    forward :child_success => :child_stop
	end.new(:id => 'a')

	plan.add_mission(a)
	a.realized_by(b = SimpleTask.new(:id => 'b'))

	b.forward(:success, a, :child_success)
	b.forward(:stop, a, :child_stop)

	FlexMock.use do |mock|
	    a.on(:child_stop) { mock.stopped }
	    mock.should_receive(:stopped).once.ordered
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
	    mock.should_receive(:command_called).with([42]).once.ordered
	    mock.should_receive(:handler_called).with([42, 24]).once.ordered
	    engine.propagate_events([seed])
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
	    plan.discover [src, dst]

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
        start_node.on(:stop) { next_event = [if_node, :start] }
	if_node.on(:stop) {  }
            
        engine.propagation_handlers << lambda do |plan|
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
	assert(size > 2, samples.map { |t| t.to_hms })

	samples.each_cons(2) do |a, b|
	    assert_in_delta(0.1, b - a, 0.001)
	end

	# Check that no samples have been added after the 'remove_periodic_handler'
	assert_equal(size, samples.size)
    end

    def test_once
	FlexMock.use do |mock|
	    engine.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	end
	FlexMock.use do |mock|
	    engine.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	    process_events
	end
    end

    def test_failing_once
	Roby.logger.level = Logger::FATAL
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
    def test_unhandled_event_exceptions
	Roby.app.abort_on_exception = true

	# Test that the event is not pending if the command raises
	model = Class.new(SimpleTask) do
	    event :start do |context|
		raise SpecificException, "bla"
            end
	end
	plan.add_mission(t = model.new)

	assert_original_error(SpecificException, CommandFailed) { t.start! }
	assert(!t.event(:start).pending?)

	# Check that the propagation is pruned if the command raises
	t = nil
	FlexMock.use do |mock|
	    t = Class.new(SimpleTask) do
		event :start do |context|
		    mock.command_called
		    raise SpecificException, "bla"
		    emit :start
                end
		on(:start) { |ev| mock.handler_called }
	    end.new
	    plan.add_mission(t)

	    mock.should_receive(:command_called).once
	    mock.should_receive(:handler_called).never

	    engine.once { t.start!(nil) }
	    assert_original_error(SpecificException, CommandFailed) { process_events }
	    assert(!t.event(:start).pending)
	end

	# Check that the task has been garbage collected in the process
	assert(! plan.include?(t))
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

	# Check on a single task
	plan.add_mission(t = SimpleTask.new)
	apply_check_structure { LocalizedError.new(t) }
	assert(! plan.include?(t))

	# Make sure that a task which has been repaired will not be killed
	plan.add_mission(t = SimpleTask.new)
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
	t0.realized_by t2
	t1.realized_by t2
	t2.realized_by t3

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
	t0.realized_by t2
	t1.realized_by t2
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

	plan.permanent(task = SimpleTask.new)
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

	plan.permanent(task = SimpleTask.new)
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

	while !t.stop?; sleep(0.1) end
	process_events

	result = t.value
	assert_kind_of(UnreachableEvent, result)
	assert_equal(task.event(:success), result.generator)

    ensure
	engine.thread = nil
    end

    class CaptureLastStats
	attr_reader :last_stats
	def splat?; true end
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
end

