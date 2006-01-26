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
            TestTask.event :start

            # Must raise because there is not terminal event
            assert_raise(TaskModelViolation) { task = TestTask.new }
            assert(! TestTask.has_event?(:stop))
            TestTask.event :ev_terminal, :terminal => true
        end

        @task = nil
        assert_nothing_raised { @task = TestTask.new }
    end
    attr_reader :task

    # Tests Task::event
    def test_event_declaration
        # Test modifications to the class hierarchy
        my_event = nil
        assert_nothing_raised   { my_event = TestTask.const_get(:EvContingent) }
        assert_raise(NameError) { TestTask.superclass.const_get(:EvContingent) }
        assert_equal( Event, my_event.superclass )
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
        event = TestTask::EvControlable.new(task)
        # Check for the definition of :call
        assert_equal(:ev_controlable, TestTask::EvControlable.call(task, :ev_controlable))
        # Check for default argument in :call
        assert_equal(task.ev_controlable, TestTask::EvControlable.call(task))
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
        assert_equal(2, task.enum_for(:each_handler, :ev_terminal).to_a.size)

        # Checks that we need :start to be called before firing any other event
        assert_raise(TaskModelViolation) { task.emit :ev_terminal }

        task.emit :start
        assert( task.running? )
        assert( !task.finished? )

        task.emit :ev_terminal
        assert event_called
        assert alias_called
        assert( task.finished? )
        assert( !task.running? )
        

        # Checks that we can't fire an event when the task is finished
        assert_raise(TaskModelViolation) { task.emit :start }
        assert_raise(TaskModelViolation) { task.emit :ev_terminal }
    end
end

