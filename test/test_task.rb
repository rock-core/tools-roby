require 'test_config'
require 'flexmock'
require 'mockups/tasks'

require 'roby/task'
require 'roby/plan'

class TC_Task < Test::Unit::TestCase 
    include RobyTestCommon

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
	task = Class.new(Task) do
	    argument :from, :to
	end.new(:from => 'B')
	assert_equal([].to_set, Task.arguments)
	assert_equal([:from, :to].to_set, task.model.arguments)

	assert(task.partially_instanciated?)
	task.arguments[:to] = 'A'
	assert_equal('A', task.arguments[:to])
	assert(!task.partially_instanciated?)
	assert_raises(ArgumentError) { task.arguments[:to] = 10 }

	task.arguments[:bar] = 42
	assert_nothing_raised { task.arguments[:bar] = 43 }
    end

    # Tests that an event is controlable if there is a method with the same
    # name in the task model
    def test_method_as_command
	FlexMock.use do |mock|
	    task = Class.new(SimpleTask) do
		define_method(:start) do |context|
		    mock.start(context)
		end
		event(:start)
	    end.new
	    mock.should_receive(:start).once
	    task.start!
	end
    end

    # Test the behaviour of Task#on, and event propagation inside a task
    def test_instance_on
	t1 = SimpleTask.new
	assert_raises(ArgumentError) { t1.on(:start) }
	
	# Test command handlers
	task = SimpleTask.new
	FlexMock.use do |mock|
	    task.on(:start)   { |event| mock.started(event.context) }
	    task.on(:start)   { |event| task.emit(:success, event.context) }
	    task.on(:success) { |event| mock.success(event.context) }
	    task.on(:stop)    { |event| mock.stopped(event.context) }
	    mock.should_receive(:started).once.with(42).ordered
	    mock.should_receive(:success).once.with(42).ordered
	    mock.should_receive(:stopped).once.with(42).ordered
	    task.start!(42)
	end
        assert(task.finished?)
	event_history = task.history.map { |ev| ev.generator }
	assert_equal([task.event(:start), task.event(:success), task.event(:stop)], event_history)

	# Same test, but with signals
	FlexMock.use do |mock|
	    t1, t2 = SimpleTask.new, SimpleTask.new
	    t1.on(:start, t2)
	    t2.on(:start) { mock.start }

	    mock.should_receive(:start).once
	    t1.start!
	end

	FlexMock.use do |mock|
	    t1, t2 = SimpleTask.new, SimpleTask.new
	    t2.start!

	    t1.on(:start, t2, :stop)
	    t2.on(:start) { mock.start }
	    t2.on(:stop)  { mock.stop }

	    mock.should_receive(:start).never
	    mock.should_receive(:stop).once
	    t1.start!
	end
    end

    def test_forward
	FlexMock.use do |mock|
	    t1, t2 = SimpleTask.new, SimpleTask.new
	    t1.forward(:start, t2)
	    t2.on(:start) { mock.start }

	    mock.should_receive(:start).once
	    t1.start!
	end

	FlexMock.use do |mock|
	    t1, t2 = SimpleTask.new, SimpleTask.new
	    t2.start!

	    t1.forward(:start, t2, :stop)
	    t2.on(:start) { mock.start }
	    t2.on(:stop) { mock.stop }

	    mock.should_receive(:start).never
	    mock.should_receive(:stop).once
	    t1.start!
	end
    end

    def test_terminal
	klass = Class.new(Task) do
	    event(:terminal_model, :terminal => true)
	    event(:terminal_model_signal)
	    event(:terminal_signal)
	    on :terminal_model_signal => :terminal_model
	end
	assert(klass.event_model(:terminal_model).terminal?)
	assert(klass.event_model(:terminal_model_signal).terminal?)
	assert(!klass.event_model(:terminal_signal).terminal?)

	task = klass.new
	assert(!task.event(:terminal_signal).terminal?)
	task.event(:terminal_signal).on task.event(:terminal_model_signal)
	assert(task.event(:terminal_signal).terminal?)
	assert(task.event(:terminal_model_signal).terminal?)
	assert(task.event(:terminal_model).terminal?)
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

	task = klass.new
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
        event = klass::EvControlable.new(task, 0, 0, nil)
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

	#Class.new(Task) do
	#    extend Test::Unit::Assertions

	#    assert_raise(ArgumentError) { event(:start, :terminal => true) }
	#    assert_raise(ArgumentError) { event(:stop, :terminal => false) }
	#    event :stop
	#    assert_nothing_raised { event(:inter, :terminal => true) }
	#    assert_raise(ArgumentError) { event(:inter, :terminal => true) }
	#end

        task = EmptyTask.new
	start_event = task.event(:start)

        assert_equal(start_event, task.event(:start))
        assert_equal([], start_event.handlers)
        assert_equal([task.event(:success)], start_event.enum_for(:each_signal).to_a)
        start_model = task.event_model(:start)
        assert_equal(start_model, start_event.event_model)
        assert_equal([:success], task.enum_for(:each_signal, :start).to_a)
    end

    def test_signal_validation
	klass = Class.new(Task) 
	t1, t2 = klass.new, klass.new

	assert(!t1.event(:stop).can_signal?(t2.event(:stop)))
	assert_raise(EventModelViolation) { t1.on(:stop, t2, :stop) }

        task = Class.new(ExecutableTask).new

	# Check can_signal? for task events
        start_event = task.event(:start)
	stop_event  = task.event(:stop)
	assert( start_event.can_signal?(stop_event) )
    end

    def test_context_propagation
	FlexMock.use do |mock|
	    task = Class.new(ExecutableTask) do
		on(:start) { |event| mock.started(event.context) }
		event(:stop)
		on(:stop) { |event| mock.stopped(event.context) }
	    end.new

	    mock.should_receive(:started).with(42).once
	    mock.should_receive(:stopped).with(21).once
	    task.start!(42)
	    task.emit(:stop, 21)
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
	assert_equal([:start, :success, :aborted, :stop, :failed, :inter].to_set, ev_models.keys.to_set)

	task = model.new
	ev_models = Hash[*task.model.enum_for(:each_event).to_a.flatten]
	assert_equal(6, ev_models.keys.size)
	assert( ev_models[:start].symbol )
	assert( ev_models[:start].name || ev_models[:start].name.length > 0 )
    end

    def test_check_running
	task = Class.new(SimpleTask) do
	    event(:inter, :command => true)
	end.new

	assert_raises(Roby::TaskModelViolation) { task.inter! }
	assert_equal(0, task.event(:inter).pending)
	task.start!
	assert_raise(Roby::TaskModelViolation) { task.start! }
	assert_nothing_raised { task.inter! }
	task.stop!

	assert_raises(Roby::TaskModelViolation) { task.inter! }
	assert_equal(0, task.event(:inter).pending)

	task = Class.new(Task) do
	    def start(context)
		inter(nil)
		emit :start
	    end
	    event :start

	    def inter(context)
		emit :inter
	    end
	    event :inter
	end.new
	task.executable = true
	assert_nothing_raised { task.start! }
    end

    def test_aborted_until
	parent, child = SimpleTask.new, SimpleTask.new

	# p:start -> c:start -> c:failed --> c:stop -> p:stop
	#				 |-> p:aborted -> p:stop
	# we make the c:failed -> p:aborted link being until p:stop
	#child.on(:stop, parent, :stop)
	#child.event(:failed).until(parent.event(:stop)).on parent.event(:aborted)

	parent.on(:start, child, :start)
	child.on(:start, child, :failed)
	parent.event(:aborted).emit_on child.event(:failed)

        FlexMock.use do |mock|
	    parent.on(:start)	{ mock.p_start }
	    child.on(:start)	{ mock.c_start }
	    child.on(:failed)	{ mock.c_failed }
	    parent.on(:aborted) { mock.p_aborted }
	    parent.on(:stop)	{ mock.p_stop }
	    child.on(:stop)	{ mock.c_stop }

	    mock.should_receive(:p_start).once.ordered
	    mock.should_receive(:c_start).once.ordered
	    mock.should_receive(:c_failed).once.ordered
	    mock.should_receive(:p_aborted).once.ordered(:aborted_stop)
	    mock.should_receive(:c_stop).once.ordered(:aborted_stop)
	    mock.should_receive(:p_stop).once.ordered

	    parent.start!
	end
    end

    def test_finished
	task = SimpleTask.new
	FlexMock.use do |mock|
	    assert(!task.finished?)
	    task.start!
	    assert(!task.finished?)
	    task.on(:stop) do
	       	mock.finished?(task.finished?) 
	    end

	    mock.should_receive(:finished?).once.with(true)
	    task.success!
	end
	assert(task.finished?)

    end

    def test_executable
	task = Class.new(SimpleTask) do 
	    event(:inter, :command => true)
	end.new
	task.executable = false

	assert_raises(TaskNotExecutable) { task.start!(nil) }
	assert_raises(EventNotExecutable) { task.event(:start).call(nil) }

	task.executable = true
	assert_nothing_raised { task.event(:start).call(nil) }

	# The task is running, cannot change the executable flag
	assert_raises(TaskModelViolation) { task.executable = false }

	task = SimpleTask.new
	plan = Plan.new
	plan.insert(task)
	assert(task.executable?)
	task.executable = false
	assert(!task.executable?)
	task.executable = nil
	assert(task.executable?)
    end

    def test_task_success_failure
	FlexMock.use do |mock|
	    t = EmptyTask.new
	    [:start, :success, :stop].each do |name|
		t.on(name) { mock.send(name) }
		mock.should_receive(name).once.ordered
	    end
	    t.start!
	end
    end

    def aggregator_test(a, *tasks)
	a.executable = true
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
	aggregator_test((t1 | t2), t1, t2)
        t1, t2 = EmptyTask.new, EmptyTask.new
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

    def test_task_sequence_aggregator
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

    def test_multi_task_signalling
	# Check a more complex setup
        start_node = EmptyTask.new
        if_node = ChoiceTask.new
        start_node.on(:stop, if_node, :start)
        start_node.start!
        assert(start_node.finished? && if_node.finished?)

	# Check history
	event_history = if_node.history.map { |ev| ev.generator }
	assert_equal(4, event_history.size, "  " + event_history.join("\n"))
	assert_equal(if_node.event(:start), event_history.first)
	assert( if_node.event(:a) == event_history[1] || if_node.event(:b) == event_history[1] )
	assert_equal(if_node.event(:stop), event_history.last)

        multi_hop = MultiEventTask.new
        multi_hop.start!
        assert(multi_hop.finished?)
	event_history = multi_hop.history.map { |ev| ev.generator }
	expected_history = [:start, :inter, :success, :stop].map { |name| multi_hop.event(name) }
	assert_equal(expected_history, event_history)
    end

    def test_task_same_state
	t1, t2 = SimpleTask.new, SimpleTask.new

	assert(t1.compatible_state?(t2))
	t1.start!; assert(! t1.compatible_state?(t2) && !t2.compatible_state?(t1))
	t1.stop!; assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))

	t1 = SimpleTask.new
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
	assert(t1.fullfills?(t1.model))
	assert(t1.fullfills?(t2))
	assert(t1.fullfills?(abstract_task_model))
	
	t2 = task_model.new(:index => 2)
	assert(!t1.fullfills?(t2))

	t3 = task_model.new(:universe => 42)
	assert(t3.fullfills?(t1))
	assert(!t1.fullfills?(t3))

	t3 = Class.new(Task).new
	assert(!t1.fullfills?(t3))

	t3 = Class.new(task_model).new
	assert(!t1.fullfills?(t3))
	assert(t3.fullfills?(t1))
    end

    def test_related_tasks
	t1, t2, t3 = (1..3).map { SimpleTask.new }
	t1.realized_by t2
	t1.event(:start).on t3.event(:start)
	assert_equal([t3].to_value_set, t1.event(:start).related_tasks)
	assert_equal([t2].to_value_set, t1.related_objects)
	assert_equal([t2, t3].to_value_set, t1.related_tasks)
    end

    def test_related_events
	t1, t2, t3 = (1..3).map { SimpleTask.new }
	t1.realized_by t2
	t1.event(:start).on t3.event(:start)
	assert_equal([t3.event(:start)].to_value_set, t1.related_events)
    end
end

