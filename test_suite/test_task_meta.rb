require 'test_config'
require 'test/unit/testcase'
require 'roby/task'

class TC_TaskMeta < Test::Unit::TestCase 
    include Roby
    class TestTask < Task
        def ev_not_controlable;     end
        def ev_method(event = :ev_method); :ev_method if event == :ev_redirected end
        def ev_controlable(event = :ev_controlable); :ev_controlable end

        event :ev_contingent
        event :ev_controlable
        event :ev_not_controlable, :command => false
        event :ev_redirected, :command => lambda { |task, event, *args| task.ev_method(event) }
    end

    def setup
        if !TestTask.has_event?(:start)
            # Must raise because :start is not set
            assert_raise(TaskModelViolation) { task = TestTask.new }
            TestTask.event :start, :command => true

            # Must raise because there is not terminal event
            assert_raise(TaskModelViolation) { task = TestTask.new }
            assert(! TestTask.has_event?(:stop))
            TestTask.event :ev_terminal, :terminal => true, :command => true
            assert( TestTask.new.respond_to?(:start!))
        end

        @task = nil
        assert_nothing_raised { @task = TestTask.new }
    end
    attr_reader :task

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
        # Test modifications to the class hierarchy
        my_event = nil
        assert_nothing_raised   { my_event = TestTask.const_get(:EvContingent) }
        assert_raise(NameError) { TestTask.superclass.const_get(:EvContingent) }
        assert_equal( TaskEvent, my_event.superclass )
        assert_equal( :ev_contingent, my_event.symbol )
        assert( TestTask.has_event?(:ev_contingent) )
    
        assert_nothing_raised   { my_event = TestTask.const_get(:EvTerminal) }
        assert_equal( :ev_terminal, my_event.symbol )

        # Check properties on EvContingent
        assert( !TestTask::EvContingent.respond_to?(:call) )
        assert( !TestTask::EvContingent.controlable? )
        assert( !TestTask::EvContingent.terminal? )

        # Check properties on EvControlable
        assert( TestTask::EvControlable.respond_to?(:call) )
        event = TestTask::EvControlable.new(task, nil)
        # Check for the definition of :call
        assert_equal(:ev_controlable, TestTask::EvControlable.call(task, :ev_controlable))
        # Check for default argument in :call
        assert_equal(task.ev_controlable, TestTask::EvControlable.call(task, nil))
        assert( TestTask::EvControlable.controlable? )

        # Check Event.terminal? if :terminal => true
        assert( TestTask::EvTerminal.terminal? )

        # Check :controlable => [proc] behaviour
        assert( TestTask::EvRedirected.controlable? )
        
        # Check that :command => false disables controlable?
        assert( :ev_not_controlable, !TestTask::EvNotControlable.controlable? )

        # Check validation of options[:command]
        assert_raise(ArgumentError) { TestTask.event :try_event, :command => "bla" }
    end

    def test_event_handling
        assert( task.has_event?(:stop) )
        assert( !task.running? )
        assert( !task.finished? )
        
        event_called = false
        alias_called = false
        task.on(:ev_terminal)   { event_called = true }
        task.on(:stop)          { alias_called = true }

        # Checks that we need :start to be called before firing any other event
        assert_raise(TaskModelViolation) { task.ev_terminal! }

        task.start!
        assert( task.running? )
        assert( !task.finished? )

        task.ev_terminal!
        assert event_called
        assert alias_called
        assert( task.finished? )
        assert( !task.running? )
        

        # Checks that we can't fire an event when the task is finished
        assert_raise(TaskModelViolation) { task.start! }
        assert_raise(TaskModelViolation) { task.ev_terminal! }
    end

    def test_inheritance
        base = Class.new(Roby::Task) do 
            extend Test::Unit::Assertions
            event :ctrl, :command => true
	    event :stop
            assert(!find_event_model(:stop).controlable?)
        end

        derived = Class.new(base) do
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
    end

    def test_singleton
	model = Class.new(Task) do
	    def initialize
		singleton_class.event(:start)
		singleton_class.event(:stop)
	    end
	    event :inter
	end

	ev_models = Hash[*model.enum_for(:each_event).to_a.flatten]
	assert_equal([:inter], ev_models.keys)

	task = model.new
	ev_models = Hash[*task.model.enum_for(:each_event).to_a.flatten]
	assert_equal(3, ev_models.keys.size)
	assert( ev_models[:start].symbol )
	assert( ev_models[:start].name || ev_models[:start].name.length > 0 )
    end
end

