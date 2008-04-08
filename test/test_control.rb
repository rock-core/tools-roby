$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'
require 'roby/test/tasks/empty_task'
require 'mockups/tasks'
require 'flexmock'
require 'utilrb/hash/slice'

class TC_Control < Test::Unit::TestCase 
    include Roby::Test

    def test_add_framework_errors
	# Shut up the logger in this test
	Roby.logger.level = Logger::FATAL
	exception = begin; raise RuntimeError
		    rescue; $!
		    end

	Roby.control.abort_on_application_exception = false
	assert_nothing_raised { Propagation.add_framework_error(exception, :exceptions) }

	Roby.control.abort_on_application_exception = true
	assert_raises(RuntimeError) { Propagation.add_framework_error(exception, :exceptions) }
    end

    def test_event_loop
        plan.insert(start_node = EmptyTask.new)
        next_event = [ start_node, :start ]
        plan.insert(if_node    = ChoiceTask.new)
        start_node.on(:stop) { |ev| next_event = [if_node, :start] }
	if_node.on(:stop) { |ev|  }
            
        Control.event_processing << lambda do 
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
	Roby.control.run :cycle => 0.1, :detach => true

	samples = []
	id = Control.every(0.1) do
	    samples << Roby.control.cycle_start
	end
	sleep(1)
	Control.remove_periodic_handler(id)
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
	    Control.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	end
	FlexMock.use do |mock|
	    Control.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	    process_events
	end
    end

    def test_failing_once
	Roby.logger.level = Logger::FATAL
	Roby.control.abort_on_exception = true
	Roby.control.run :detach => true

	FlexMock.use do |mock|
	    Control.once { mock.called; raise }
	    mock.should_receive(:called).once

	    assert_raises(ControlQuitError) do
		Roby.wait_one_cycle
		Roby.control.join
	    end
	end
    end

    class SpecificException < RuntimeError; end
    def test_unhandled_event_exceptions
	Roby.control.abort_on_exception = true

	# Test that the event is not pending if the command raises
	model = Class.new(SimpleTask) do
	    event :start do |context|
		raise SpecificException, "bla"
            end
	end
	plan.insert(t = model.new)

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
	    plan.insert(t)

	    mock.should_receive(:command_called).once
	    mock.should_receive(:handler_called).never

	    Control.once { t.start!(nil) }
	    assert_original_error(SpecificException, CommandFailed) { process_events }
	    assert(!t.event(:start).pending)
	end

	# Check that the task has been garbage collected in the process
	assert(! plan.include?(t))
    end

    def apply_structure_checking(&block)
	Control.structure_checks.clear
	Control.structure_checks << lambda(&block)
	process_events
    ensure
	Control.structure_checks.clear
    end

    def test_structure_checking
	Roby.logger.level = Logger::FATAL
	Roby.control.abort_on_exception = false

	# Check on a single task
	plan.insert(t = SimpleTask.new)
	apply_structure_checking { LocalizedError.new(t) }
	assert(! plan.include?(t))

	# Make sure that a task which has been repaired will not be killed
	plan.insert(t = SimpleTask.new)
	did_once = false
	apply_structure_checking do
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

	plan.insert(t0)
	plan.insert(t1)
	FlexMock.use do |mock|
	    mock.should_receive(:checking).twice
	    apply_structure_checking do
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
	plan.insert(t0)
	plan.insert(t1)
	apply_structure_checking { { LocalizedError.new(t2) => t0 } }
	assert(!plan.include?(t0))
	assert(plan.include?(t1))
	assert(plan.include?(t2))
    end

    def test_at_cycle_end
	# Shut up the logger in this test
	Roby.logger.level = Logger::FATAL
        Roby.control.abort_on_application_exception = false

        FlexMock.use do |mock|
            mock.should_receive(:before_error).at_least.once
            mock.should_receive(:after_error).never
            mock.should_receive(:called).at_least.once

            Control.at_cycle_end do
		mock.before_error
		raise
		mock.after_error
            end

            Control.at_cycle_end do
		mock.called
		unless Roby.control.quitting?
		    Roby.control.quit
		end
            end
            Roby.control.run
        end
    end

    def test_inside_outside_control
	# First, no control thread
	assert(Roby.inside_control?)
	assert(Roby.outside_control?)

	# Add a fake control thread
	begin
	    Roby.control.thread = Thread.main
	    assert(Roby.inside_control?)
	    assert(!Roby.outside_control?)

	    t = Thread.new do
		assert(!Roby.inside_control?)
		assert(Roby.outside_control?)
	    end
	    t.value
	ensure
	    Roby.control.thread = nil
	end

	# .. and test with the real one
	Roby.control.run :detach => true
	Roby.execute do
	    assert(Roby.inside_control?)
	    assert(!Roby.outside_control?)
	end
	assert(!Roby.inside_control?)
	assert(Roby.outside_control?)
    end

    def test_execute
	# Set a fake control thread
	Roby.control.thread = Thread.main

	FlexMock.use do |mock|
	    mock.should_receive(:thread_before).once.ordered
	    mock.should_receive(:main_before).once.ordered
	    mock.should_receive(:execute).once.ordered.with(Thread.current).and_return(42)
	    mock.should_receive(:main_after).once.ordered(:finish)
	    mock.should_receive(:thread_after).once.ordered(:finish)

	    returned_value = nil
	    t = Thread.new do
		mock.thread_before
		returned_value = Roby.execute do
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
	Roby.control.thread = nil
    end

    def test_execute_error
	assert(!Roby.control.thread)
	# Set a fake control thread
	Roby.control.thread = Thread.main
	assert(!Roby.control.quitting?)

	returned_value = nil
	t = Thread.new do
	    returned_value = begin
				 Roby.execute do
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
	assert(!Roby.control.quitting?)

    ensure
	Roby.control.thread = nil
    end
    
    def test_wait_until
	# Set a fake control thread
	Roby.control.thread = Thread.main

	plan.permanent(task = SimpleTask.new)
	t = Thread.new do
	    Roby.wait_until(task.event(:start)) do
		task.start!
	    end
	end

	while !t.stop?; sleep(0.1) end
	process_events
	assert_nothing_raised { t.value }

    ensure
	Roby.control.thread = nil
    end
 
    def test_wait_until_unreachable
	# Set a fake control thread
	Roby.control.thread = Thread.main

	plan.permanent(task = SimpleTask.new)
	t = Thread.new do
	    begin
		Roby.wait_until(task.event(:success)) do
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
	Roby.control.thread = nil
    end

    class CaptureLastStats
	attr_reader :last_stats
	def splat?; true end
	def cycle_end(time, stats)
	    @last_stats = stats
	end
    end
    
    def test_stats
	Roby.control.run :detach => true, :cycle => 0.1

	capture = CaptureLastStats.new
	Roby::Log.add_logger capture

	time_events = [:real_start, :events, :structure_check, :exception_propagation, :exception_fatal, :garbage_collect, :application_errors, :ruby_gc, :sleep, :end]
	10.times do
	    Roby.control.wait_one_cycle
	    next unless capture.last_stats

	    Roby::Control.synchronize do
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

