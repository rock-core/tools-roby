require 'test_config'
require 'test/unit/testcase'
require 'roby/relations/executed_by'
require 'roby/task'
require 'flexmock'
require 'mockups/tasks'

class TC_Task < Test::Unit::TestCase 
    include Roby

    def test_base_model
	task = Class.new(Task) do
	    event(:start)
	    event(:stop1)
	    event(:stop2)
	    event(:stop3)
	    event(:stop)
	    on :stop1 => :stop
	end.new
	task.on(:stop2, task, :stop1)
	task.on(:stop3, task, :stop)
	assert(task.event(:aborted).terminal?)
	assert(task.event(:stop1).terminal?)
	assert(task.event(:stop2).terminal?)
	assert(task.event(:stop3).terminal?)
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

	# Must raise because :start is not set
	assert_raise(TaskModelViolation) { task = klass.new }
	klass.event :start, :command => true

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
        event = klass::EvControlable.new(task, 0, 0)
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
    end

    def test_event_def_validation
	Class.new(Task) do
	    extend Test::Unit::Assertions

	    assert_raise(TaskModelViolation) { event(:start, :terminal => true) }
	    assert_raise(TaskModelViolation) { event(:stop, :terminal => false) }
	    event :stop
	    assert_nothing_raised { event(:inter, :terminal => true) }
	    assert_raise(ArgumentError) { event(:inter, :terminal => true) }
	end
    end

    def test_event_properties
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
	klass = Class.new(Task) do
	    event :start
	    event :stop
	end
	t1, t2 = klass.new, klass.new
	assert_raise(EventModelViolation) { t1.on(:stop, t2, :start) }
    end

    def test_task_propagation
        task = Class.new(Task) do
	    event :start, :command => true
	    event :success, :command => true, :terminal => true
	end.new

	# Check can_signal? for task events
        start_event = task.event(:start)
	stop_event  = task.event(:stop)
	assert( start_event.can_signal?(stop_event) )

	# Check that propagation is done properly in this simple task
	FlexMock.use do |mock|
	    task.on(:start) { |event| mock.started(event.context) }
	    task.on(:start) { |event| task.emit(:success, event.context) }
	    task.on(:success) { |event| mock.success(event.context) }
	    task.on(:stop) { |event| mock.stopped(event.context) }
	    mock.should_receive(:started).once.with(42).ordered
	    mock.should_receive(:success).once.with(42).ordered
	    mock.should_receive(:stopped).once.with(42).ordered
	    task.start!(42)
	end
        assert(task.finished?)
	event_history = task.history.map { |_, ev| ev.generator }
	assert_equal([task.event(:start), task.event(:success), task.event(:stop)], event_history)
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
		singleton_class.event(:start)
		singleton_class.event(:stop)
		super
	    end
	    event :inter
	end

	ev_models = Hash[*model.enum_for(:each_event).to_a.flatten]
	assert_equal([:success, :aborted, :failed, :inter].to_set, ev_models.keys.to_set)

	task = model.new
	ev_models = Hash[*task.model.enum_for(:each_event).to_a.flatten]
	assert_equal(6, ev_models.keys.size)
	assert( ev_models[:start].symbol )
	assert( ev_models[:start].name || ev_models[:start].name.length > 0 )
    end

    def test_check_running
	task = Class.new(Roby::Task) do
	    event(:start, :command => true)
	    event(:inter, :command => true)
	    event(:stop, :command => true)
	end.new

	assert_raises(Roby::TaskModelViolation) { task.inter! }
	assert_equal(0, task.event(:inter).pending)
	task.start!
	assert_raise(Roby::TaskModelViolation) { task.start! }
	assert_nothing_raised { task.inter! }
	task.stop!

	assert_raises(Roby::TaskModelViolation) { task.inter! }
	assert_equal(0, task.event(:inter).pending)
    end

    def test_aborted_until
	klass = Class.new(Roby::Task) do
	    event(:start, :command => true)
	    event(:stop, :command => true)
	end
	parent, child = klass.new, klass.new

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

    def test_aborted_default_handler
	klass = Class.new(Roby::Task) do
	    event(:start, :command => true)
	    event(:ready, :command => true)
	end

	t1, t2, t3 = klass.new, klass.new, klass.new
	t1.add_child(t2)
	t1.executed_by(t3)

	FlexMock.use do |mock|
	    t1.on(:start) { mock.t1_start }
	    t2.on(:stop) { mock.t2_stop }

	    t3.event(:aborted).on { mock.t3 }
	    t1.event(:aborted).on { mock.t1 }

	    mock.should_receive(:t1_start).once.ordered
	    mock.should_receive(:t2_stop).never
	    mock.should_receive(:t3).once.ordered
	    mock.should_receive(:t1).once.ordered

	    t3.start!
	    t1.start!
	    t2.start!
	    t3.ready!
	    t3.emit(:aborted, nil)
	end
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

    def test_task_sequence_aggregator
        t1, t2 = EmptyTask.new, EmptyTask.new
	aggregator_test( (t1 + t2), t1, t2 )
        t1, t2 = EmptyTask.new, EmptyTask.new
	s = t1 + t2
	aggregator_test( s.to_task, t1, t2 )
	assert(! t1.event(:stop).related_object?(s.event(:stop)))

        t1, t2, t3 = EmptyTask.new, EmptyTask.new, EmptyTask.new
        s = t2 + t3
	s.unshift t1
	aggregator_test(s, t1, t2, t3)
	
        t1, t2, t3 = EmptyTask.new, EmptyTask.new, EmptyTask.new
        s = t2 + t3
	s.unshift t1
	aggregator_test(s.to_task, t1, t2, t3)
    end

    def test_multi_task_signalling
	# Check a more complex setup
        start_node = EmptyTask.new
        if_node = ChoiceTask.new
        start_node.on(:stop, if_node, :start)
        start_node.start!
        assert(start_node.finished? && if_node.finished?)

	# Check history
	event_history = if_node.history.map { |_, ev| ev.generator }
	assert_equal(4, event_history.size, "  " + event_history.join("\n"))
	assert_equal(if_node.event(:start), event_history.first)
	assert( if_node.event(:a) == event_history[1] || if_node.event(:b) == event_history[1] )
	assert_equal(if_node.event(:stop), event_history.last)

        multi_hop = MultiEventTask.new
        multi_hop.start!
        assert(multi_hop.finished?)
	event_history = multi_hop.history.map { |_, ev| ev.generator }
	expected_history = [:start, :inter, :success, :stop].map { |name| multi_hop.event(name) }
	assert_equal(expected_history, event_history)
    end

    def test_task_same_state
	klass = Class.new(Task) do
	    event(:start, :command => true)
	    event(:stop, :command => true)
	end
	t1, t2 = klass.new, klass.new

	assert(t1.same_state?(t2))
	t1.start!; assert(! t1.same_state?(t2) && !t2.same_state?(t1))
	t1.stop!; assert(! t1.same_state?(t2) && !t2.same_state?(t1))

	t1 = klass.new
	t1.start!
	t2.start!; assert(t1.same_state?(t2) && t2.same_state?(t1))
	t1.stop!; assert(! t1.same_state?(t2) && !t2.same_state?(t1))
    end

    def test_fullfills
	task_model = Class.new(Task) do
	    event :start
	end

	t1, t2 = task_model.new, task_model.new
	assert(t1.fullfills?(t1.model))
	assert(t1.fullfills?(t2))
	
	t2 = task_model.new(:index => 2)
	assert(!t1.fullfills?(t2))

	t3 = task_model.new(:universe => 42)
	assert(t3.fullfills?(t1))
	assert(!t1.fullfills?(t3))

	t3 = Class.new(Task) do
	    event :start
	end.new
	assert(!t1.fullfills?(t3))

	t3 = Class.new(task_model) do
	    event :start
	end.new
	assert(!t1.fullfills?(t3))
	assert(t3.fullfills?(t1))
    end

end

