$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'
require 'roby/test/tasks/empty_task'
require 'flexmock'

class TC_Task < Test::Unit::TestCase 
    include Roby::Test

    def test_model_tag
	my_tag = TaskModelTag.new do
	    argument :model_tag
	end
	assert(my_tag.const_defined?(:ClassExtension))
	assert(my_tag::ClassExtension.method_defined?(:argument))
	task = Class.new(Task) do
	    include my_tag
	    argument :task_tag
	end
	assert_equal([:task_tag, :model_tag].to_set, task.arguments.to_set)
    end

    def test_arguments
	model = Class.new(Task) do
	    arguments :from, :to
	end
	plan.discover(task = model.new(:from => 'B', :useless => 'bla'))
	assert_equal([], Task.arguments.to_a)
	assert_equal([:from, :to].to_value_set, task.model.arguments.to_value_set)
	assert_equal({:from => 'B', :useless => 'bla'}, task.arguments)
	assert_equal({:from => 'B'}, task.meaningful_arguments)

	assert(task.partially_instanciated?)
	task.arguments[:to] = 'A'
	assert_equal('A', task.arguments[:to])
	assert(!task.partially_instanciated?)
	assert_raises(ArgumentError) { task.arguments[:to] = 10 }

	task.arguments[:bar] = 42
	assert_nothing_raised { task.arguments[:bar] = 43 }
    end

    def test_command_block
	FlexMock.use do |mock|
	    model = Class.new(SimpleTask) do 
		event :start do |context|
		    mock.start(self, context)
		    emit :start
		end
	    end
	    plan.insert(task = model.new)
	    mock.should_receive(:start).once.with(task, [42])
	    task.start!(42)
	end
    end

    Precedence = Roby::EventStructure::Precedence
    def assert_direct_precedence(task, relations)
	relations.each do |from, to|
	    from = task.event(from)
	    to   = to.map { |sym| task.event(sym) }

	    assert_equal(to.to_value_set, from.child_objects(Precedence).to_value_set, from.symbol)
	end
    end

    def test_instantiate_model_event_relations
	# Create a task model with two intermediate events being
	# linked by a causal link
	task = Class.new(Roby::Test::SimpleTask) do
	    event :first
	    event :second
	    event :third
	    causal_link :first => :third
	    causal_link :second => :third
	end.new
	plan.discover(task)

	assert_direct_precedence task, 
	    :start => [:first, :second, :updated_data],
	    :first => [:third],
	    :second => [:third],
	    :third => [:success, :aborted],
	    :aborted => [:failed],
	    :failed => [:stop],
	    :success => [:stop]

    end

    # Tests that an event is controlable if there is a method with the same
    # name in the task model
    def test_command_method
	FlexMock.use do |mock|
	    model = Class.new(SimpleTask) do
		define_method(:start) do |context|
		    mock.start(self, context)
		    emit :start
		end
		event(:start)
	    end
	    plan.insert(task = model.new)
	    mock.should_receive(:start).once.with(task, [42])
	    task.start!(42)
	end
    end

    # Test the behaviour of Task#on, and event propagation inside a task
    def test_instance_on
	plan.discover(t1 = SimpleTask.new)
	assert_raises(ArgumentError) { t1.on(:start) }
	
	# Test command handlers
	plan.insert(task = SimpleTask.new)
	FlexMock.use do |mock|
	    task.on(:start)   { |event| mock.started(event.context) }
	    task.on(:start)   { |event| task.emit(:success, *event.context) }
	    task.on(:success) { |event| mock.success(event.context) }
	    task.on(:stop)    { |event| mock.stopped(event.context) }
	    mock.should_receive(:started).once.with([42]).ordered
	    mock.should_receive(:success).once.with([42]).ordered
	    mock.should_receive(:stopped).once.with([42]).ordered
	    task.start!(42)
	end
        assert(task.finished?)
	event_history = task.history.map { |ev| ev.generator }
	assert_equal([task.event(:start), task.event(:success), task.event(:stop)], event_history)

	# Same test, but with signals
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :missions => 2, :model => SimpleTask
	    t1.on(:start, t2)
	    t2.on(:start) { mock.start }

	    mock.should_receive(:start).once
	    t1.start!
	end

	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :missions => 2, :model => SimpleTask
	    t2.start!

	    t1.on(:start, t2, :stop)
	    t2.on(:start) { mock.start }
	    t2.on(:stop)  { mock.stop }

	    mock.should_receive(:start).never
	    mock.should_receive(:stop).once
	    t1.start!
	end

	t = prepare_plan :missions => 1, :model => SimpleTask
	e = EventGenerator.new(true)
	t.on(:start, e)
	t.start!
	assert(e.happened?)
    end

    def test_model_event_handling
	model = Class.new(SimpleTask) do
	    forward :start => :failed
	end
	assert_equal({ :start => [:failed, :stop].to_value_set }, model.forwarding_sets)
	assert_equal({}, SimpleTask.signal_sets)

	assert_equal([:failed, :stop].to_value_set, model.forwardings(:start))
	assert_equal([:stop].to_value_set, model.forwardings(:failed))
	assert_equal(model.forwardings(:failed), model.enum_for(:each_forwarding, :failed).to_value_set)

	FlexMock.use do |mock|
	    model.on :start do
		mock.start_called(self)
	    end
	    plan.discover(task = model.new)
	    mock.should_receive(:start_called).with(task).once
	    task.start!
	    assert(task.failed?)
	end

	# Make sure the model-level signal is not applied to parent models
	plan.discover(task = SimpleTask.new)
	task.start!
	assert(!task.failed?)
    end

    def test_forward
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :missions => 2, :model => SimpleTask
	    t1.forward(:start, t2)
	    t2.on(:start) { mock.start }

	    mock.should_receive(:start).once
	    t1.start!
	end

	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :missions => 2, :model => SimpleTask
	    t2.start!

	    t1.forward(:start, t2, :stop)
	    t2.on(:start) { mock.start }
	    t2.on(:stop) { mock.stop }

	    mock.should_receive(:start).never
	    mock.should_receive(:stop).once
	    t1.start!
	end


	FlexMock.use do |mock|
	    t1 = prepare_plan :missions => 1, :model => SimpleTask
	    ev = EventGenerator.new do 
		mock.called
		ev.emit
	    end
	    ev.on { mock.emitted }
	    t1.forward(:start, ev)

	    mock.should_receive(:called).never
	    mock.should_receive(:emitted).once
	    t1.start!
	end
    end

    def test_terminal
	klass = Class.new(Task) do
	    event(:terminal_model, :terminal => true)
	    event(:terminal_model_signal)
	    forward :terminal_model_signal => :terminal_model

	    event(:success_model, :terminal => true)
	    event(:success_model_signal)
	    forward :success_model_signal => :success
	    forward :success_model_signal => :success_model

	    event(:failure_model, :terminal => true)
	    event(:failure_model_signal)
	    forward :failure_model_signal => :failed
	    forward :failure_model_signal => :failure_model

	    event(:ev)
	end
	assert(klass.event_model(:stop).terminal?)
	assert(klass.event_model(:success).terminal?)
	assert(klass.event_model(:failed).terminal?)
	assert(klass.event_model(:terminal_model).terminal?)
	assert(klass.event_model(:terminal_model_signal).terminal?)

	plan.discover(task = klass.new)
	assert(task.event(:stop).terminal?)
	assert(!task.event(:stop).success?)
	assert(!task.event(:stop).failure?)
	assert(task.event(:success).terminal?)
	assert(task.event(:success).success?)
	assert(!task.event(:success).failure?)
	assert(task.event(:failed).terminal?)
	assert(!task.event(:failed).success?)
	assert(task.event(:failed).failure?)

	ev = task.event(:ev)
	assert(!ev.terminal?)
	assert(!ev.success?)
	assert(!ev.failure?)
	ev.forward task.event(:terminal_model_signal)
	assert(ev.terminal?)
	assert(!ev.success?)
	assert(!ev.failure?)
	ev.forward task.event(:success_model_signal)
	assert(ev.terminal?)
	assert(ev.success?)
	assert(!ev.failure?)
	ev.remove_forwarding task.event(:success_model_signal)
	ev.forward task.event(:failure_model_signal)
	assert(ev.terminal?)
	assert(!ev.success?)
	assert(ev.failure?)
    end

    # Tests Task::event
    def test_event_declaration
	klass = Class.new(Task) do
	    def ev_not_controlable;     end
	    def ev_method(event = :ev_method); :ev_method if event == :ev_redirected end
	    def ev_controlable(event = :ev_controlable); :ev_controlable end

	    event :ev_contingent
	    event :ev_controlable
	    event :ev_not_controlable, :command => false
	    event :ev_redirected, :command => lambda { |task, event, *args| task.ev_method(event) }
	end

	# Must raise because there is not terminal event
	klass.event :ev_terminal, :terminal => true, :command => true

	plan.discover(task = klass.new)
	assert_respond_to(task, :start!)

        # Test modifications to the class hierarchy
        my_event = nil
        assert_nothing_raised   { my_event = klass.const_get(:EvContingent) }
        assert_raise(NameError) { klass.superclass.const_get(:EvContingent) }
        assert_equal( TaskEvent, my_event.superclass )
        assert_equal( :ev_contingent, my_event.symbol )
        assert( klass.has_event?(:ev_contingent) )
    
        assert_nothing_raised   { my_event = klass.const_get(:EvTerminal) }
        assert_equal( :ev_terminal, my_event.symbol )

        # Check properties on EvContingent
        assert( !klass::EvContingent.respond_to?(:call) )
        assert( !klass::EvContingent.controlable? )
        assert( !klass::EvContingent.terminal? )

        # Check properties on EvControlable
        assert( klass::EvControlable.respond_to?(:call) )
        event = klass::EvControlable.new(task, task.event(:ev_controlable), 0, nil)
        # Check for the definition of :call
        assert_equal(:ev_controlable, klass::EvControlable.call(task, :ev_controlable))
        # Check for default argument in :call
        assert_equal(task.ev_controlable, klass::EvControlable.call(task, nil))
        assert( klass::EvControlable.controlable? )

        # Check Event.terminal? if :terminal => true
        assert( klass::EvTerminal.terminal? )

        # Check :controlable => [proc] behaviour
        assert( klass::EvRedirected.controlable? )
        
        # Check that :command => false disables controlable?
        assert( :ev_not_controlable, !klass::EvNotControlable.controlable? )

        # Check validation of options[:command]
        assert_raise(ArgumentError) { klass.event :try_event, :command => "bla" }

        plan.discover(task = EmptyTask.new)
	start_event = task.event(:start)

        assert_equal(start_event, task.event(:start))
        assert_equal([], start_event.handlers)
	# Note that the start => stop forwarding is added because 'start' is
	# detected as terminal in the EmptyTask model
        assert_equal([task.event(:stop), task.event(:success)].to_set, start_event.enum_for(:each_forwarding).to_set)
        start_model = task.event_model(:start)
        assert_equal(start_model, start_event.event_model)
        assert_equal([:stop, :success].to_set, task.enum_for(:each_forwarding, :start).to_set)
    end
    def test_status
	task = Class.new(Roby::Task) do
	    event :start do
	    end
	    event :failed, :terminal => true do
	    end
	    event :stop do
		failed!
	    end
	end.new
	plan.discover(task)

	assert(task.pending?)
	assert(!task.starting?)
	assert(!task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(!task.finishing?)
	assert(!task.finished?)

	task.start!
	assert(!task.pending?)
	assert(task.starting?)
	assert(!task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(!task.finishing?)
	assert(!task.finished?)

	task.emit(:start)
	assert(!task.pending?)
	assert(!task.starting?)
	assert(task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(!task.finishing?)
	assert(!task.finished?)

	task.stop!
	assert(!task.pending?)
	assert(!task.starting?)
	assert(task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(task.finishing?)
	assert(!task.finished?)

	task.emit(:failed)
	assert(!task.pending?)
	assert(!task.starting?)
	assert(!task.running?)
	assert(!task.success?)
	assert(task.failed?)
	assert(!task.finishing?)
	assert(task.finished?)
    end

    def test_context_propagation
	FlexMock.use do |mock|
	    model = Class.new(SimpleTask) do
		event :start do |context|
		    mock.starting(context)
		    event(:start).emit(*context)
		end
		on(:start) do |event| 
		    mock.started(event.context)
		end


		event :pass_through, :command => true
		on(:pass_through) do |event|
		    mock.pass_through(event.context)
		end

		on(:stop)  { |event| mock.stopped(event.context) }
	    end
	    plan.insert(task = model.new)

	    mock.should_receive(:starting).with([42]).once
	    mock.should_receive(:started).with([42]).once
	    mock.should_receive(:pass_through).with([10]).once
	    mock.should_receive(:stopped).with([21]).once
	    task.start!(42)
	    task.pass_through!(10)
	    task.emit(:stop, 21)
	    assert(task.finished?)
	end
    end

    def test_inheritance_overloading
        base = Class.new(Roby::Task) do 
            extend Test::Unit::Assertions
            event :ctrl, :command => true
	    event :stop
            assert(!find_event_model(:stop).controlable?)
        end

        Class.new(base) do
            extend Test::Unit::Assertions

            assert_nothing_raised { event :start, :command => true }
            assert_raises(ArgumentError) { event :ctrl, :command => false }
            assert_raises(ArgumentError) { event :failed, :terminal => false }
            assert_raises(ArgumentError) { event :failed }

            def stop(context)
            end
            assert_nothing_raised { event :stop }
            assert(find_event_model(:stop).controlable?)
        end

	Class.new(base) do
	    def start(context)
	    end
	    assert_nothing_raised { event :start }
	end
    end

    def test_singleton
	model = Class.new(Task) do
	    def initialize
		singleton_class.event(:start, :command => true)
		singleton_class.event(:stop)
		super
	    end
	    event :inter
	end

	ev_models = Hash[*model.enum_for(:each_event).to_a.flatten]
	assert_equal([:start, :success, :aborted, :updated_data, :stop, :failed, :inter].to_set, ev_models.keys.to_set)

	plan.discover(task = model.new)
	ev_models = Hash[*task.model.enum_for(:each_event).to_a.flatten]
	assert_equal([:start, :success, :aborted, :updated_data, :stop, :failed, :inter].to_set, ev_models.keys.to_set)
	assert( ev_models[:start].symbol )
	assert( ev_models[:start].name || ev_models[:start].name.length > 0 )
    end

    def test_check_running
	model = Class.new(SimpleTask) do
	    event(:inter, :command => true)
	end
	plan.insert(task = model.new)

	assert_raises(EmissionFailed) { task.inter! }
	assert(!task.event(:inter).pending)
	task.start!
	assert_raise(EmissionFailed) { task.start! }
	assert_nothing_raised { task.inter! }
	task.stop!

	assert_raises(EmissionFailed) { task.inter! }
	assert(!task.event(:inter).pending)

	model = Class.new(SimpleTask) do
	    def start(context)
		inter(nil)
		emit :start
	    end
	    event :start

	    def inter(context)
		emit :inter
	    end
	    event :inter
	end
	plan.discover(task = model.new)
	assert_nothing_raised { task.start! }
    end

    def test_finished
	model = Class.new(Roby::Task) do
	    event :start, :command => true
	    event :failed, :command => true, :terminal => true
	    event :success, :command => true, :terminal => true
	    event :stop, :command => true
	end

	plan.insert(task = model.new)
	task.start!
	task.emit(:stop)
	assert(!task.success?)
	assert(!task.failed?)
	assert(task.finished?)
	assert_equal(task.event(:stop).last, task.terminal_event)

	plan.insert(task = model.new)
	task.start!
	task.emit(:success)
	assert(task.success?)
	assert(!task.failed?)
	assert(task.finished?)
	assert_equal(task.event(:success).last, task.terminal_event)

	plan.insert(task = model.new)
	task.start!
	task.emit(:failed)
	assert(!task.success?)
	assert(task.failed?)
	assert(task.finished?)
	assert_equal(task.event(:failed).last, task.terminal_event)
    end

    def test_executable
	model = Class.new(SimpleTask) do 
	    event(:inter, :command => true)
	end
	task = model.new

	assert(!task.executable?)
	assert_raises(EventNotExecutable) { task.start! }
	assert_raises(EventNotExecutable) { task.event(:start).call }

	plan.discover(task)
	assert(task.executable?)
	assert_nothing_raised { task.event(:start).call(nil) }

	# The task is running, cannot change the executable flag
	assert_raises(ModelViolation) { task.executable = false }

	task = SimpleTask.new
	plan.insert(task)
	assert(task.executable?)
	task.executable = false
	assert(!task.executable?)
	task.executable = nil
	assert(task.executable?)

	task = SimpleTask.new
	plan.permanent(task)
	assert(task.executable?)
	task.executable = false
	assert(!task.executable?)
	task.executable = nil
	assert(task.executable?)
    end

    def test_task_success_failure
	FlexMock.use do |mock|
	    plan.insert(t = EmptyTask.new)
	    [:start, :success, :stop].each do |name|
		t.on(name) { mock.send(name) }
		mock.should_receive(name).once.ordered
	    end
	    t.start!
	end
    end

    def aggregator_test(a, *tasks)
	plan.insert(a)
	FlexMock.use do |mock|
	    [:start, :success, :stop].each do |name|
		a.on(name) { mock.send(name) }
		mock.should_receive(name).once.ordered
	    end
	    a.start!
	    assert( tasks.all? { |t| t.finished? })
	end
    end

    def test_task_parallel_aggregator
        t1, t2 = EmptyTask.new, EmptyTask.new
	plan.discover([t1, t2])
	aggregator_test((t1 | t2), t1, t2)
        t1, t2 = EmptyTask.new, EmptyTask.new
	plan.discover([t1, t2])
	aggregator_test( (t1 | t2).to_task, t1, t2 )
    end

    def task_tuple(count)
	tasks = (1..count).map do 
	    t = EmptyTask.new
	    t.executable = true
	    t
	end
	yield(tasks)
    end

    def test_sequence
	task_tuple(2) { |t1, t2| aggregator_test( (t1 + t2), t1, t2 ) }
        task_tuple(2) do |t1, t2| 
	    s = t1 + t2
	    aggregator_test( s.to_task, t1, t2 )
	    assert(! t1.event(:stop).related_object?(s.event(:stop)))
	end

	task_tuple(3) do |t1, t2, t3|
	    s = t2 + t3
	    s.unshift t1
	    aggregator_test(s, t1, t2, t3)
	end
	
	task_tuple(3) do |t1, t2, t3|
	    s = t2 + t3
	    s.unshift t1
	    aggregator_test(s.to_task, t1, t2, t3)
	end
    end
    def test_sequence_to_task
	model = Class.new(SimpleTask)
	t1, t2 = prepare_plan :tasks => 2, :model => SimpleTask

	seq = (t1 + t2)
	assert(seq.child_object?(t1, TaskStructure::Hierarchy))
	assert(seq.child_object?(t2, TaskStructure::Hierarchy))

	task = seq.to_task(model)

	plan.insert(task)

	assert(!seq.child_object?(t1, TaskStructure::Hierarchy))
	assert(!seq.child_object?(t2, TaskStructure::Hierarchy))

	task.start!
	assert(t1.running?)
	t1.success!
	assert(t2.running?)
	t2.success!
	assert(task.success?)
    end

    def test_compatible_state
	t1, t2 = prepare_plan :missions => 2, :model => SimpleTask

	assert(t1.compatible_state?(t2))
	t1.start!; assert(! t1.compatible_state?(t2) && !t2.compatible_state?(t1))
	t1.stop!; assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))

	plan.insert(t1 = SimpleTask.new)
	t1.start!
	t2.start!; assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))
	t1.stop!; assert(t1.compatible_state?(t2) && !t2.compatible_state?(t1))
    end

    def test_fullfills
	abstract_task_model = TaskModelTag.new do
	    argument :abstract
	end
	task_model = Class.new(Task) do
	    include abstract_task_model
	    argument :index, :universe
	end

	t1, t2 = task_model.new, task_model.new
	plan.discover([t1, t2])
	assert(t1.fullfills?(t1.model))
	assert(t1.fullfills?(t2))
	assert(t1.fullfills?(abstract_task_model))
	
	plan.discover(t2 = task_model.new(:index => 2))
	assert(!t1.fullfills?(t2))

	plan.discover(t3 = task_model.new(:universe => 42))
	assert(t3.fullfills?(t1))
	assert(!t1.fullfills?(t3))

	plan.discover(t3 = Class.new(Task).new)
	assert(!t1.fullfills?(t3))

	plan.discover(t3 = Class.new(task_model).new)
	assert(!t1.fullfills?(t3))
	assert(t3.fullfills?(t1))
    end

    def test_related_tasks
	t1, t2, t3 = (1..3).map { SimpleTask.new }.
	    each { |t| plan.discover(t) }
	t1.realized_by t2
	t1.event(:start).on t3.event(:start)
	assert_equal([t3].to_value_set, t1.event(:start).related_tasks)
	assert_equal([t2].to_value_set, t1.related_objects)
	assert_equal([t2, t3].to_value_set, t1.related_tasks)
    end

    def test_related_events
	t1, t2, t3 = (1..3).map { SimpleTask.new }.
	    each { |t| plan.discover(t) }
	t1.realized_by t2
	t1.event(:start).on t3.event(:start)
	assert_equal([t3.event(:start)].to_value_set, t1.related_events)
    end

    def test_if_unreachable
	model = Class.new(SimpleTask) do
	    event :ready
	end

	# Test that the stop event will make the handler called on a running task
	FlexMock.use do |mock|
	    plan.discover(task = model.new)
	    ev = task.event(:success)
	    ev.if_unreachable(false) { mock.success_called }
	    ev.if_unreachable(true)  { mock.success_cancel_called }
	    mock.should_receive(:success_called).once
	    mock.should_receive(:success_cancel_called).never
	    ev = task.event(:ready)
	    ev.if_unreachable(false) { mock.ready_called }
	    ev.if_unreachable(true)  { mock.ready_cancel_called }
	    mock.should_receive(:ready_called).once
	    mock.should_receive(:ready_cancel_called).once

	    task.start!
	    task.success!
	end
	plan.garbage_collect

	# Test that it works on pending tasks too
	FlexMock.use do |mock|
	    plan.discover(task = model.new)
	    ev = task.event(:success)
	    ev.if_unreachable(false) { mock.success_called }
	    ev.if_unreachable(true)  { mock.success_cancel_called }
	    mock.should_receive(:success_called).once
	    mock.should_receive(:success_cancel_called).once

	    ev = task.event(:ready)
	    ev.if_unreachable(false) { mock.ready_called }
	    ev.if_unreachable(true)  { mock.ready_cancel_called }
	    mock.should_receive(:ready_called).once
	    mock.should_receive(:ready_cancel_called).once

	    plan.garbage_collect
	end

    end

    def test_achieve_with
	slave  = SimpleTask.new
	master = Class.new(Task) do
	    terminates
	    event :start do
		event(:start).achieve_with slave
	    end
	end.new
	plan.discover([master, slave])

	master.start!
	assert(master.starting?)
	assert(master.realized_by?(slave))
	slave.start!
	slave.success!
	assert(master.started?)

	slave  = SimpleTask.new
	master = Class.new(Task) do
	    event :start do
		event(:start).achieve_with slave.event(:start)
	    end
	end.new
	plan.discover([master, slave])

	master.start!
	assert(master.starting?)
	assert_raises(UnreachableEvent) { plan.remove_object(slave) }
    end

    def test_task_group
	t1, t2 = SimpleTask.new, SimpleTask.new
	plan.discover(g = Group.new(t1, t2))

	g.start!
	assert(t1.running?)
	assert(t2.running?)

	t1.success!
	assert(g.running?)
	t2.success!
	assert(g.success?)
    end

    def test_task_poll
	Roby.control.run :cycle => 0.1, :detach => true

	FlexMock.use do |mock|
	    t = Class.new(SimpleTask) do
		poll do
		    mock.polled(self)
		end
	    end.new
	    mock.should_receive(:polled).at_least.once.with(t)

	    Roby.execute do
		plan.permanent(t)
		t.start!
	    end
	    sleep(1)
	    Roby.execute do
		assert(t.running?, t.terminal_event.to_s)
		t.stop!
	    end
	end

	FlexMock.use do |mock|
	    mock.should_receive(:polled).at_least.once
	    t = Class.new(SimpleTask) do
		poll do
		    mock.polled(self)
		    raise ArgumentError
		end
	    end.new

	    Roby.execute do
		plan.permanent(t)
		t.start!
	    end
	    sleep(1)
	    assert(t.failed?)
	end
    end
end

