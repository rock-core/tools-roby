$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'
require 'roby/test/tasks/empty_task'
require 'flexmock'

class TC_Task < Test::Unit::TestCase 
    include Roby::Test
    def setup
        super
        Roby.app.filter_backtraces = false
    end

    def test_model_tag
        tag1 = TaskModelTag.new { argument :model_tag_1 }
	assert(tag1.const_defined?(:ClassExtension))
	assert(tag1::ClassExtension.method_defined?(:argument))

	tag2 = TaskModelTag.new do
            include tag1
            argument :model_tag_2
        end
	assert(tag2 < tag1)
	assert(tag2.const_defined?(:ClassExtension))
	assert(tag2::ClassExtension.method_defined?(:argument))

	task = Class.new(Task) do
	    include tag2
	    argument :task_tag
	end
	assert_equal([:task_tag, :model_tag_2, :model_tag_1].to_set, task.arguments.to_set)
    end

    def test_arguments
	model = Class.new(Task) do
	    arguments :from, :to
	end
	plan.add(task = model.new(:from => 'B', :useless => 'bla'))
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
	    plan.add_mission(task = model.new)
	    mock.should_receive(:start).once.with(task, [42])
	    task.start!(42)
	end
    end

    def test_command_inheritance
        FlexMock.use do |mock|
            parent_m = Class.new(SimpleTask) do
                event :start do |context|
                    mock.parent_started(self, context)
                    emit :start
                end
            end

            child_m = Class.new(parent_m) do
                event :start do |context|
                    mock.child_started(self, context.first)
                    super(context.first / 2)
                end
            end

            plan.add_mission(task = child_m.new)
            mock.should_receive(:parent_started).once.with(task, 21)
            mock.should_receive(:child_started).once.with(task, 42)
            task.start!(42)
        end
    end

    def assert_task_relation_set(task, relation, expected)
        plan.add(task)
        task.each_event do |from|
            task.each_event do |to|
                next if from == to
                exp = expected[from.symbol]
                if exp == to.symbol || (exp.respond_to?(:include?) && exp.include?(to.symbol))
                    assert from.child_object?(to, relation), "expected relation #{from} => #{to} in #{relation} is missing"
                else
                    assert !from.child_object?(to, relation), "unexpected relation #{from} => #{to} found in #{relation}"
                end
            end
        end
    end

    def do_test_instantiate_model_relations(method, relation, additional_links = Hash.new)
	klass = Class.new(Roby::Test::SimpleTask) do
            4.times { |i| event "e#{i + 1}", :command => true }
            send(method, :e1 => [:e2, :e3], :e4 => :stop)
	end

        plan.add(task = klass.new)
        expected_links = Hash[:e1 => [:e2, :e3], :e4 => :stop]
        
        assert_task_relation_set task, relation, expected_links.merge(additional_links)
    end
    def test_instantiate_model_signals
        do_test_instantiate_model_relations(:signal, EventStructure::Signal)
    end
    def test_instantiate_deprecated_model_on
        deprecated_feature do
            do_test_instantiate_model_relations(:on, EventStructure::Signal)
        end
    end
    def test_instantiate_model_forward
        do_test_instantiate_model_relations(:forward, EventStructure::Forwarding,
                           :success => :stop, :aborted => :failed, :failed => :stop)
    end
    def test_instantiate_model_causal_links
        do_test_instantiate_model_relations(:causal_link, EventStructure::CausalLink,
                           :success => :stop, :aborted => :failed, :failed => :stop)
    end

    
    def do_test_inherit_model_relations(method, relation, additional_links = Hash.new)
	base = Class.new(Roby::Test::SimpleTask) do
            4.times { |i| event "e#{i + 1}", :command => true }
            send(method, :e1 => [:e2, :e3])
	end
        subclass = Class.new(base) do
            send(method, :e4 => :stop)
        end

        task = base.new
        assert_task_relation_set task, relation,
            Hash[:e1 => [:e2, :e3]].merge(additional_links)

        task = subclass.new
        assert_task_relation_set task, relation,
            Hash[:e1 => [:e2, :e3], :e4 => :stop].merge(additional_links)
    end
    def test_inherit_model_signals
        do_test_inherit_model_relations(:signal, EventStructure::Signal)
    end
    def test_inherit_deprecated_model_on
        deprecated_feature do
            do_test_inherit_model_relations(:on, EventStructure::Signal)
        end
    end
    def test_inherit_model_forward
        do_test_inherit_model_relations(:forward, EventStructure::Forwarding,
                           :success => :stop, :aborted => :failed, :failed => :stop)
    end
    def test_inherit_model_causal_links
        do_test_inherit_model_relations(:causal_link, EventStructure::CausalLink,
                           :success => :stop, :aborted => :failed, :failed => :stop)
    end

    # Test the behaviour of Task#on, and event propagation inside a task
    def test_instance_event_handlers
	plan.add(t1 = SimpleTask.new)
	assert_raises(ArgumentError) { t1.on(:start) }
	
	plan.add(task = SimpleTask.new)
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
    end

    def test_instance_signals
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :add => 3, :model => SimpleTask
            t1.signals(:start, t2, :start)

            t2.on(:start) { mock.start }
            mock.should_receive(:start).once
	    t1.start!
	end
    end

    def test_instance_signals_deprecated_default_event_name
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :add => 3, :model => SimpleTask
            deprecated_feature do
                t1.on(:start, t2)
            end

            t2.on(:start) { mock.start }
            mock.should_receive(:start).once
	    t1.start!
	end
    end

    def test_instance_signals_deprecated_on_usage
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :add => 3, :model => SimpleTask
            deprecated_feature do
                t1.on(:start, t2, :start)
            end

            t2.on(:start) { mock.start }
            mock.should_receive(:start).once
	    t1.start!
	end
    end

    def test_instance_signals_plain_events
	t = prepare_plan :missions => 1, :model => SimpleTask
	e = EventGenerator.new(true)
	t.signals(:start, e)
	t.start!
	assert(e.happened?)
    end

    def test_instance_signals_plain_events_deprecated_on_usage
	t = prepare_plan :missions => 1, :model => SimpleTask
	e = EventGenerator.new(true)
        deprecated_feature do
            t.on(:start, e)
        end
	t.start!
	assert(e.happened?)
    end

    def test_model_forwardings
	model = Class.new(SimpleTask) do
	    forward :start => :failed
	end
	assert_equal({ :start => [:failed, :stop].to_value_set }, model.forwarding_sets)
	assert_equal({}, SimpleTask.signal_sets)

	assert_equal([:failed, :stop].to_value_set, model.forwardings(:start))
	assert_equal([:stop].to_value_set,          model.forwardings(:failed))
	assert_equal([:stop].to_value_set,          model.enum_for(:each_forwarding, :failed).to_value_set)

        plan.add(task = model.new)
        task.start!

	# Make sure the model-level relation is not applied to parent models
	plan.add(task = SimpleTask.new)
	task.start!
	assert(!task.failed?)
    end

    def test_model_event_handlers
	model = Class.new(SimpleTask)
        assert_raises(ArgumentError) { model.on(:start) { || } }
        assert_raises(ArgumentError) { model.on(:start) { |a, b| } }

	FlexMock.use do |mock|
	    model.on :start do
		mock.start_called(self)
	    end
	    plan.add(task = model.new)
	    mock.should_receive(:start_called).with(task).once
	    task.start!

            # Make sure the model-level handler is not applied to parent models
            plan.add(task = SimpleTask.new)
            task.start!
            assert(!task.failed?)
	end
    end

    def test_instance_forward_to
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :missions => 2, :model => SimpleTask
	    t1.forward_to(:start, t2, :start)
	    t2.on(:start) { mock.start }

	    mock.should_receive(:start).once
	    t1.start!
	end
    end

    def test_instance_forward_to_plain_events
	FlexMock.use do |mock|
	    t1 = prepare_plan :missions => 1, :model => SimpleTask
	    ev = EventGenerator.new do 
		mock.called
		ev.emit
	    end
	    ev.on { mock.emitted }
	    t1.forward_to(:start, ev)

	    mock.should_receive(:called).never
	    mock.should_receive(:emitted).once
	    t1.start!
	end
    end

    def test_terminal_option
	klass = Class.new(Task) do
            event :terminal, :terminal => true
        end
        assert klass.event_model(:terminal).terminal?
        plan.add(task = klass.new)
        assert task.event(:terminal).terminal?
        assert task.event(:terminal).child_object?(task.event(:stop), EventStructure::Forwarding)
    end

    def test_terminal_direct_forward_in_model
	klass = Class.new(Task) do
	    event :terminal
	    forward :terminal => :stop
	end
        assert klass.event_model(:terminal).terminal?
        plan.add(task = klass.new)
        assert task.event(:terminal).terminal?
    end

    def test_terminal_indirect_forward_in_model
	klass = Class.new(Task) do
	    event :terminal
            event :intermediate

            forward :intermediate => :failed
	    forward :terminal => :intermediate
	end
        assert klass.event_model(:terminal).terminal?
        plan.add(task = klass.new)
        assert task.event(:terminal).terminal?
    end

    def test_terminal_direct_signal_in_model
	klass = Class.new(SimpleTask) do
	    event :terminal
	    signal :terminal => :stop
	end
        assert klass.event_model(:terminal).terminal?
        plan.add(task = klass.new)
        assert task.event(:terminal).terminal?
    end

    def test_terminal_indirect_signal_in_model
	klass = Class.new(Task) do
	    event :terminal
            event :intermediate, :command => true

	    signal :terminal => :intermediate
            forward :intermediate => :failed
	end
        assert klass.event_model(:terminal).terminal?
        plan.add(task = klass.new)
        assert task.event(:terminal).terminal?
    end

    def test_should_not_establish_signal_from_terminal_to_non_terminal
	klass = Class.new(Task) do
	    event :terminal, :terminal => true
            event :intermediate
	end
        assert_raises(ArgumentError) { klass.forward :terminal => :intermediate }
        klass.new
    end

    def test_should_not_establish_signal_from_terminal_to_non_terminal
	klass = Class.new(Task) do
	    event :terminal, :terminal => true
            event :intermediate, :command => true
	end
        assert_raises(ArgumentError) { klass.signal :terminal => :intermediate }
        klass.new
    end

    # Tests Task::event
    def test_event_declaration
	klass = Class.new(Task) do
	    def ev_not_controlable;     end
	    def ev_method(event = :ev_method); :ev_method if event == :ev_redirected end

	    event :ev_contingent
	    event :ev_controlable do |*events|
                :ev_controlable
            end

	    event :ev_not_controlable
	    event :ev_redirected, :command => lambda { |task, event, *args| task.ev_method(event) }
	end

	klass.event :ev_terminal, :terminal => true, :command => true

	plan.add(task = klass.new)
	assert_respond_to(task, :start!)
        assert_respond_to(task, :start?)

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
        assert( klass::EvControlable.controlable? )
        assert( klass::EvControlable.respond_to?(:call) )
        event = klass::EvControlable.new(task, task.event(:ev_controlable), 0, nil)
        assert_equal(:ev_controlable, klass::EvControlable.call(task, :ev_controlable))

        # Check Event.terminal? if :terminal => true
        assert( klass::EvTerminal.terminal? )

        # Check :controlable => [proc] behaviour
        assert( klass::EvRedirected.controlable? )
        
        # Check that :command => false disables controlable?
        assert( :ev_not_controlable, !klass::EvNotControlable.controlable? )

        # Check validation of options[:command]
        assert_raise(ArgumentError) { klass.event :try_event, :command => "bla" }

        plan.add(task = EmptyTask.new)
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
	plan.add(task)

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
	    plan.add_mission(task = model.new)

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

            assert_nothing_raised { event(:stop) { |context| } }
            assert(find_event_model(:stop).controlable?)
        end

	Class.new(base) do
	    assert_nothing_raised { event(:start) { |context| } }
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

	plan.add(task = model.new)
	ev_models = Hash[*task.model.enum_for(:each_event).to_a.flatten]
	assert_equal([:start, :success, :aborted, :updated_data, :stop, :failed, :inter].to_set, ev_models.keys.to_set)
	assert( ev_models[:start].symbol )
	assert( ev_models[:start].name || ev_models[:start].name.length > 0 )
    end

    def test_check_running
	model = Class.new(SimpleTask) do
	    event(:inter, :command => true)
	end
	plan.add(task = model.new)

	assert_raises(CommandFailed) { task.inter! }
	assert_raises(EmissionFailed) { task.emit(:inter) }
	assert(!task.event(:inter).pending)
	task.start!
	assert_raise(CommandFailed) { task.start! }
	assert_nothing_raised { task.inter! }
	task.stop!

	assert_raises(EmissionFailed) { task.emit(:inter) }
	assert_raises(CommandFailed) { task.inter! }
	assert(!task.event(:inter).pending)

	model = Class.new(SimpleTask) do
	    event :start do |context|
		emit :inter
		emit :start
            end

	    event :inter do |context|
		emit :inter
            end
	end
	plan.add(task = model.new)
	assert_nothing_raised { task.start! }
    end

    def test_finished
	model = Class.new(Roby::Task) do
	    event :start, :command => true
	    event :failed, :command => true, :terminal => true
	    event :success, :command => true, :terminal => true
	    event :stop, :command => true
	end

	plan.add(task = model.new)
	task.start!
	task.emit(:stop)
	assert(!task.success?)
	assert(!task.failed?)
	assert(task.finished?)
	assert_equal(task.event(:stop).last, task.terminal_event)

	plan.add(task = model.new)
	task.start!
	task.emit(:success)
	assert(task.success?)
	assert(!task.failed?)
	assert(task.finished?)
	assert_equal(task.event(:success).last, task.terminal_event)

	plan.add(task = model.new)
	task.start!
	task.emit(:failed)
	assert(!task.success?)
	assert(task.failed?)
	assert(task.finished?)
	assert_equal(task.event(:failed).last, task.terminal_event)
    end

    def assert_exception_message(klass, msg)
        yield
        flunk 'no exception raised'
    rescue klass => e
        unless msg === e.message
            flunk "exception message '#{e.message}' does not match the expected pattern"
        end
    rescue Exception => e
        flunk "expected an exception of class #{klass} but got #{e.full_message}"
    end

    def test_executable
	model = Class.new(SimpleTask) do 
	    event(:inter, :command => true)
	end
	task = model.new

	assert(!task.executable?)
	assert_raises(EventNotExecutable) { task.start! }
	assert_raises(EventNotExecutable) { task.event(:start).call }



	plan.add(task)
	assert(task.executable?)
	assert_nothing_raised { task.event(:start).call(nil) }

	# The task is running, cannot change the executable flag
	assert_raises(ModelViolation) { task.executable = false }

	task = SimpleTask.new
	plan.add_mission(task)
	assert(task.executable?)
	task.executable = false
	assert(!task.executable?)
	task.executable = nil
	assert(task.executable?)

	task = SimpleTask.new
	plan.add_permanent(task)
	assert(task.executable?)
	task.executable = false
	assert(!task.executable?)
	task.executable = nil
	assert(task.executable?)
    end
	
    class ParameterizedTask < Roby::Task
        arguments :arg
    end
    
    class AbstractTask < Roby::Task
        abstract
    end

    class NotExecutablePlan < Roby::Plan
        def executable?
            false
	end
    end
    
    def exception_propagator(task, relation)
	first_task  = SimpleTask.new
	second_task = task
	first_task.send(relation, :start, second_task, :start)
	first_task.start!
    end
    
    def check_direct_start(substring, check_signaling)
        error = yield
	assert_exception_message(EventNotExecutable, substring) { error.start! }
        error = yield
	assert_exception_message(EventNotExecutable, substring) {error.event(:start).call(nil)}
        error = yield
	assert_exception_message(EventNotExecutable, substring) {error.event(:start).emit(nil)}
	
	if check_signaling then
	    error = yield
	    assert_exception_message(EventNotExecutable, substring) do
	       exception_propagator(error, :signals)
	    end
	    error = yield
	    assert_exception_message(EventNotExecutable, substring) do
	       exception_propagator(error, :forward_to)
	    end
	end
    end
        
    def test_exception_refinement
	# test for partially instanciation
	check_direct_start(/partially instanciated/,true) do
	   plan.add(task = ParameterizedTask.new)
	   task
	end

        #test for a task that is in no plan
        check_direct_start(/no plan/,false) do
            SimpleTask.new
	end
        
        #test for an abstract task
        check_direct_start(/abstract/,true) do
            plan.add(task = AbstractTask.new)
            task
	end
	
	#test for a not executable plan
	erroneous_plan = NotExecutablePlan.new	
	check_direct_start(/plan is not executable/,false) do
	   erroneous_plan.add(task = SimpleTask.new)
	   task
	end
        erroneous_plan.clear
        
        #test for a not executable task
        check_direct_start(/is not executable/,true) do
            plan.add(task = SimpleTask.new)
            task.executable = false
            task
	end
    end
	
    

    def test_task_success_failure
	FlexMock.use do |mock|
	    plan.add_mission(t = EmptyTask.new)
	    [:start, :success, :stop].each do |name|
		t.on(name) { mock.send(name) }
		mock.should_receive(name).once.ordered
	    end
	    t.start!
	end
    end

    def aggregator_test(a, *tasks)
	plan.add_mission(a)
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
	plan.add([t1, t2])
	aggregator_test((t1 | t2), t1, t2)
        t1, t2 = EmptyTask.new, EmptyTask.new
	plan.add([t1, t2])
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

	plan.add_mission(task)

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
	t1, t2 = prepare_plan :add => 2, :model => SimpleTask

	assert(t1.compatible_state?(t2))
	t1.start!; assert(! t1.compatible_state?(t2) && !t2.compatible_state?(t1))
	t1.stop!; assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))

	plan.add(t1 = SimpleTask.new)
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
	plan.add([t1, t2])
	assert(t1.fullfills?(t1.model))
	assert(t1.fullfills?(t2))
	assert(t1.fullfills?(abstract_task_model))
	
	plan.add(t2 = task_model.new(:index => 2))
	assert(!t1.fullfills?(t2))

	plan.add(t3 = task_model.new(:universe => 42))
	assert(t3.fullfills?(t1))
	assert(!t1.fullfills?(t3))

	plan.add(t3 = Class.new(Task).new)
	assert(!t1.fullfills?(t3))

	plan.add(t3 = Class.new(task_model).new)
	assert(!t1.fullfills?(t3))
	assert(t3.fullfills?(t1))
    end

    def test_related_tasks
	t1, t2, t3 = (1..3).map { SimpleTask.new }.
	    each { |t| plan.add(t) }
	t1.depends_on t2
	t1.event(:start).signals t3.event(:start)
	assert_equal([t3].to_value_set, t1.event(:start).related_tasks)
	assert_equal([t2].to_value_set, t1.related_objects)
	assert_equal([t2, t3].to_value_set, t1.related_tasks)
    end

    def test_related_events
	t1, t2, t3 = (1..3).map { SimpleTask.new }.
	    each { |t| plan.add(t) }
	t1.depends_on t2
	t1.event(:start).signals t3.event(:start)
	assert_equal([t3.event(:start)].to_value_set, t1.related_events)
    end

    def test_if_unreachable
	model = Class.new(SimpleTask) do
	    event :ready
	end

	# Test that the stop event will make the handler called on a running task
	FlexMock.use do |mock|
	    plan.add(task = model.new)
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
	engine.garbage_collect

	# Test that it works on pending tasks too
	FlexMock.use do |mock|
	    plan.add(task = model.new)
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

	    engine.garbage_collect
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
	plan.add([master, slave])

	master.start!
	assert(master.starting?)
	assert(master.depends_on?(slave))
	slave.start!
	slave.success!
	assert(master.started?)

	slave  = SimpleTask.new
	master = Class.new(Task) do
	    event :start do
		event(:start).achieve_with slave.event(:start)
	    end
	end.new
	plan.add([master, slave])

	master.start!
	assert(master.starting?)
	assert_raises(UnreachableEvent) { plan.remove_object(slave) }
    end

    def test_task_group
	t1, t2 = SimpleTask.new, SimpleTask.new
	plan.add(g = Group.new(t1, t2))

	g.start!
	assert(t1.running?)
	assert(t2.running?)

	t1.success!
	assert(g.running?)
	t2.success!
	assert(g.success?)
    end

    def test_task_poll
	engine.run

	FlexMock.use do |mock|
	    t = Class.new(SimpleTask) do
		poll do
		    mock.polled(self)
		end
	    end.new
	    mock.should_receive(:polled).at_least.once.with(t)

	    engine.execute do
		plan.add_permanent(t)
		t.start!
	    end
	    engine.wait_one_cycle
	    engine.execute do
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

	    engine.execute do
		plan.add_permanent(t)
		t.start!
	    end
	    engine.wait_one_cycle
	    assert(t.failed?)
	end
    end

    def test_event_task_sources
	task = Class.new(SimpleTask) do
	    event :specialized_failure, :command => true
	    forward :specialized_failure => :failed
	end.new
	plan.add(task)

	task.start!
	assert_equal([task.event(:start).last], task.event(:start).last.task_sources.to_a)

	ev = EventGenerator.new(true)
	ev.forward_to task.event(:specialized_failure)
	ev.call
	assert_equal([task.event(:specialized_failure).last], task.event(:stop).last.task_sources.to_a)
    end

    def test_virtual_task
	start, success = EventGenerator.new(true), EventGenerator.new
	assert_raises(ArgumentError) { VirtualTask.create(success, start) }

	assert_kind_of(VirtualTask, task = VirtualTask.create(start, success))
	plan.add(task)
	assert_equal(start, task.start_event)
	assert_equal(success, task.success_event)
	FlexMock.use do |mock|
	    start.on { mock.start_event }
	    task.event(:start).on { mock.start_task }
	    mock.should_receive(:start_event).once.ordered
	    mock.should_receive(:start_task).once.ordered
	    task.start!

	    success.emit
	    assert(task.success?)
	end

	start, success = EventGenerator.new(true), EventGenerator.new
	plan.add(task = VirtualTask.create(start, success))
	task.start!
	plan.remove_object(success)
	assert(task.failed?)

	start, success = EventGenerator.new(true), EventGenerator.new
	plan.add(success)
	plan.add(task = VirtualTask.create(start, success))
	assert_nothing_raised { success.emit }
    end

    def test_dup
	plan.add(task = Roby::Test::SimpleTask.new)
	task.start!

	new = task.dup
	assert_not_same(new.event(:stop), task.event(:stop))
	assert_same(new, new.event(:stop).task)
	assert(plan.include?(new))
	assert_kind_of(Roby::TaskArguments, new.arguments)
	assert_equal(task.arguments.to_hash, new.arguments.to_hash)
	assert_same(plan, new.plan)
	assert(new.event(:failed).child_object?(new.event(:stop), Roby::EventStructure::Forwarding))

	task.stop!
	assert(!task.running?)
	assert(new.running?)

	new.event(:stop).call
	assert(new.finished?, new.history)
    end
end

