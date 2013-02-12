$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock/test_unit'
require 'roby/tasks/simple'

require 'roby'

class TC_Exceptions < Test::Unit::TestCase 
    include Roby::SelfTest
    include Roby::SelfTest::Assertions
    class SpecializedError < LocalizedError; end

    DO_PRETTY_PRINT = false

    def test_execution_exception_initialize
	plan.add(task = Task.new)
	error = ExecutionException.new(LocalizedError.new(task))
	assert_equal(task, error.task)
	assert_equal([task], error.trace)
	assert_equal(nil, error.generator)

	ev = task.event(:start)
	error = ExecutionException.new(LocalizedError.new(ev))
	assert_equal(task, error.task)
	assert_equal(ev, error.generator)
	assert_equal([task], error.trace)
    end

    def test_execution_exception_fork
	task, t1, t2, t3 = prepare_plan :add => 5
	e = ExecutionException.new(LocalizedError.new(task))
	s = e.fork

	assert_equal([e, s], e.siblings)
	assert_equal([e, s], s.siblings)
	e.trace << t1
	s.trace << t2
	assert_equal([task, t1], e.trace)
	assert_equal([task, t2], s.trace)

	e.merge(s)
	assert_equal([task, [t1, t2]], e.trace)

	s = e.fork
	e.merge(s)
	assert_equal([t1, t2], e.task)
	assert_equal(task, e.origin)

	s = e.fork
	s.trace << t3
	e.merge(s)
	assert_equal([t1, t2, t3], e.task)
	assert_equal(task, e.origin)

	e = ExecutionException.new(LocalizedError.new(task))
	s = e.fork
	t1, t2 = prepare_plan :add => 2
	s.trace << t1 << t2
	e.merge(s)
	assert_equal([task, t2], e.task)
	assert_equal(task, e.origin)

	e = ExecutionException.new(LocalizedError.new(task))
	s = e.fork
	e.merge(s)
	assert_equal(task, e.task)
	assert_equal(task, e.origin)
    end

    class SignallingHandler < Roby::LocalizedError; end
    def test_task_handle_exception
	FlexMock.use do |mock|
	    received_handler2 = false
	    klass = Task.new_submodel do 
		on_exception(SpecializedError) do |exception|
		    mock.handler1(exception, exception.task, self)
		end
		on_exception(SpecializedError) do |exception|
		    if received_handler2
			pass_exception
		    end
		    received_handler2 = true
		    mock.handler2(exception, exception.task, self)
		end
		on_exception(RuntimeError) do |exception|
		    pass_exception
		end
		on_exception(SignalException) do |exception|
		    raise
		end
	    end

	    plan.add(task  = klass.new)
	    error = ExecutionException.new(SpecializedError.new(task))
	    mock.should_receive(:handler2).with(error, task, task).once.ordered
	    mock.should_receive(:handler1).with(error, task, task).once.ordered
	    assert(task.handle_exception(error))
	    assert(task.handle_exception(error))

	    error = ExecutionException.new(CodeError.new(nil, task))
	    assert(! task.handle_exception(error))
	    error = ExecutionException.new(SignallingHandler.new(task))
	    assert(! task.handle_exception(error))
	end
    end

    def test_linear_propagation
	FlexMock.use do |mock|
	    t1, t2 = Task.new, Task.new
	    t0 = Task.new_submodel do 
		on_exception(SpecializedError) do |exception|
		    mock.handler(exception, exception.task, self)
		end
	    end.new
	    plan.add(t0)
	    t0.depends_on t1
	    t1.depends_on t2

	    error = ExecutionException.new(SpecializedError.new(t2))
	    mock.should_receive(:handler).with(error, t1, t0).once
	    assert_equal([], engine.propagate_exceptions([error]))
	    assert_equal([error], error.siblings)
	    assert_equal([t2, t1], error.trace)

	    error = ExecutionException.new(CodeError.new(nil, t2))
	    assert_equal([error], engine.propagate_exceptions([error]))
	    assert_equal(t0, error.task)
	    assert_equal([t2, t1, t0], error.trace)

	    # Redo that but this time define a global exception handler
	    error = ExecutionException.new(CodeError.new(nil, t2))
	    plan.on_exception(CodeError) do |mod, exception|
		mock.global_handler(exception, exception.task, mod)
	    end
	    mock.should_receive(:global_handler).with(error, t0, plan).once
	    assert_equal([], engine.propagate_exceptions([error]))
	end
    end

    def test_forked_propagation
	# We build a 0 -> 1 -> 2 3 -> 2 task tree with
	# 0 being able to handle the exception and 1, 3 not

	FlexMock.use do |mock|
	    t1, t2, t3 = prepare_plan :add => 3
	    t0 = Task.new_submodel do 
		attr_accessor :handled_exception
		on_exception(Roby::CodeError) do |exception|
		    self.handled_exception = exception
		    mock.handler(exception, exception.task, self)
		end
	    end.new
	    plan.add(t0)
	    t0.depends_on t1
	    t1.depends_on t2
	    t3.depends_on t2

	    error = ExecutionException.new(CodeError.new(nil, t2))
	    mock.should_receive(:handler).with(ExecutionException, t1, t0).once
	    # There are two possibilities here:
	    #	1/ the error propagation begins with t1 -> t0, in which case +error+
	    #	   is t0.handled_exception and there may be no sibling (the error is
	    #	   never tested on t3
	    #	2/ propagation begins with t3, in which case +error+ is a sibling of
	    #	   t0.handled_exception
	    assert_equal([], engine.propagate_exceptions([error]))
	    assert_equal([t2, t1], t0.handled_exception.trace)
	    if t0.handled_exception != error
		assert_equal([t2, t3], error.trace)
		assert_equal([t0.handled_exception, error].to_set, error.siblings.to_set)
	    end

	    error = ExecutionException.new(LocalizedError.new(t2))
	    assert(fatal = engine.propagate_exceptions([error]))
	    assert_equal(1, fatal.size)
	    e = fatal.first
	    assert_equal(t2, e.origin)
	    assert_equal([t3, t0], e.task)
	end
    end

    def test_diamond_propagation
	# We build a 0 -> 1 -> 2 3 -> 2 task tree with
	# 0 being able to handle the exception and 1, 3 not

	FlexMock.use do |mock|
	    t1, t2, t3 = prepare_plan :add => 3

	    found_exception = nil
	    t0 = Task.new_submodel do 
		on_exception(Roby::LocalizedError) do |exception|
		    found_exception = exception
		    mock.handler(exception, exception.task.to_set, self)
		end
	    end.new
	    plan.add(t0)
	    t0.depends_on t1 ; t1.depends_on t2
	    t0.depends_on t3 ; t3.depends_on t2
	    

	    error = ExecutionException.new(LocalizedError.new(t2))
	    mock.should_receive(:handler).with(ExecutionException, [t1, t3].to_set, t0).once
	    assert_equal([], engine.propagate_exceptions([error]))
	    assert_equal(2, found_exception.trace.size, found_exception.trace)
	    assert_equal(t2, found_exception.origin)
	    assert_equal([t3, t1].to_set, found_exception.task.to_set)
	end
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
        assert_nothing_raised do
            Task.new_submodel.on_exception(RuntimeError) do |_|
            end
        end

        assert_raises(ArgumentError) do |a, b|
            plan.on_exception(RuntimeError) do |_|
            end
        end
        assert_nothing_raised do
            plan.on_exception(RuntimeError) do |_, _|
            end
        end
    end

    def test_exception_propagation_merging
	FlexMock.use do |mock|
	    t11 = Task.new(:id => '11')
	    t12 = Task.new(:id => '12')
	    t13 = Task.new(:id => '13')

	    root = Task.new_submodel do
		include Test::Unit::Assertions
		on_exception(RuntimeError) do |exception|
		    assert_equal([t11, t12, t13].to_set, exception.task.to_set)
		    mock.caught(exception.task)
		end
	    end.new(:id => 'root')
	    plan.add(root)
	    root.depends_on(t11)
	    root.depends_on(t12)
	    root.depends_on(t13)

	    t11.depends_on(t21 = Task.new(:id => '21'))
	    t12.depends_on(t21)

	    t13.depends_on(t22 = Task.new(:id => '22'))
	    t22.depends_on(t31 = Task.new(:id => '31'))
	    t31.depends_on(t21)

	    mock.should_receive(:caught).once
	    engine.propagate_exceptions([ExecutionException.new(LocalizedError.new(t21))])
	end
    end

    def test_plan_repairs
	model = Tasks::Simple.new_submodel do
	    event :blocked
	    forward :blocked => :failed
	end

	# First, check methods located in Plan
	plan.add(task = model.new)
	r1, r2 = Tasks::Simple.new, Tasks::Simple.new

	task.start!
	task.emit :blocked

	blocked_event = task.history[-3]
	failed_event  = task.history[-2]
	stop_event    = task.history[-1]
	plan.add_repair failed_event, r1
	plan.add_repair blocked_event, r2
	assert(plan.task_index.repaired_tasks.include?(task))

	assert_equal({}, plan.repairs_for(stop_event))
	assert_equal({failed_event => r1}, plan.repairs_for(failed_event))
	assert_equal({blocked_event => r2, failed_event => r1}, plan.repairs_for(blocked_event))
	plan.remove_repair r1
	assert_equal({}, plan.repairs_for(failed_event))
	assert_equal({blocked_event => r2}, plan.repairs_for(blocked_event))
	plan.remove_repair r2
	assert_equal({}, plan.repairs_for(stop_event))
	assert_equal({}, plan.repairs_for(failed_event))
	assert_equal({}, plan.repairs_for(blocked_event))
	assert(!plan.task_index.repaired_tasks.include?(task))
    end

    def test_exception_inhibition
	parent, child = prepare_plan :add => 2, :model => Tasks::Simple
	parent.depends_on child
	parent.signals :start, child, :start
	parent.start!
	plan.add(repairing_task = Tasks::Simple.new)
	repairing_task.start!
        inhibit_fatal_messages do
            assert_raises(ChildFailedError) { child.failed! }
        end

	exceptions = plan.check_structure
	assert_equal(exceptions.to_a, engine.remove_inhibited_exceptions(exceptions))
	assert_equal(exceptions.keys, engine.propagate_exceptions(exceptions))

	plan.add_repair(child.terminal_event, repairing_task)
	assert_equal([], engine.remove_inhibited_exceptions(exceptions))
	assert_equal([], engine.propagate_exceptions(exceptions))

    ensure
	# Remove the child so that the test's plan cleanup does not complain
	parent.remove_child child if child
    end

    def test_error_handling_relation(error_event = :failed)
	task_model = Tasks::Simple.new_submodel do
	    event :blocked
	    forward :blocked => :failed
	end

	parent, (child, *repair_tasks) = prepare_plan :permanent => 1, :add => 3, :model => task_model
	parent.depends_on child
	child.event(:failed).handle_with repair_tasks[0]
	child.event(:failed).handle_with repair_tasks[1]

	parent.start!
	child.start!
	child.emit error_event

	exceptions = plan.check_structure

	assert_equal([], engine.propagate_exceptions(exceptions))

        repairs = plan.repairs_for(child.terminal_event)
        repair_task = repair_tasks.find { |t| repairs[child.terminal_event] == t }
        assert(repair_task)

	Roby.app.abort_on_exception = false
	process_events
	assert(repair_task.running?)
	process_events
	assert(repair_task.running?)

	# Make the "repair task" finish, but do not repair the plan.
	# propagate_exceptions must not add a new repair
	repair_task.success!
	assert_equal(exceptions.keys, engine.propagate_exceptions(exceptions))

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

    def test_code_error_formatting
        model = Tasks::Simple.new_submodel do
            event :start do |context|
                raise ArgumentError
            end
        end
        task = prepare_plan :permanent => 1, :model => model
        inhibit_fatal_messages do
            error = begin task.start!
                    rescue Exception => e; e
                    end
            check_exception_formatting(e)
        end


        model = Tasks::Simple.new_submodel do
            event :start do |context|
                start_event.emit_failed
            end
        end
        task = prepare_plan :permanent => 1, :model => model
        inhibit_fatal_messages do
            error = begin task.start!
                    rescue Exception => e; e
                    end
            check_exception_formatting(e)
        end

        model = Tasks::Simple.new_submodel do
            on :start do |ev|
                raise ArgumentError
            end
        end
        task = prepare_plan :add => 1, :model => model
        inhibit_fatal_messages do
            error = begin
                        with_log_level(Roby, Logger::FATAL) do
                            task.start!
                        end
                    rescue Exception => e; e
                    end
            check_exception_formatting(e)
        end
    end

    def check_exception_formatting(error)
        if DO_PRETTY_PRINT
            STDERR.puts "---- #{error.class}"
            Roby.format_exception(error).each do |line|
                STDERR.puts line
            end
        else
            Roby.format_exception(error)
        end
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
                assert_equal [t1, t2].to_set, engine.fatal.to_set
            end
        end
        assert_equal(1, messages.size)
        name, time, (error, tasks) = *messages.first
        assert_equal('fatal_exception', name)
        assert_equal([t1.remote_id, t2.remote_id].to_set, tasks.to_set)
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
end

