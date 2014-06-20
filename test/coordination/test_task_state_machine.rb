require 'roby/test/self'
require 'roby/tasks/simple'
require 'roby/test/tasks/empty_task'

class TC_TaskStateMachine < Minitest::Test
    class TestTask < Roby::Task
        refine_running_state do
            on :one do 
                transition [:running, :zero] => :one
            end

            on :two do
                transition [:one] => :two
            end

            on :three do
                transition [:two] => :three
            end

            on :reset do
                transition all => :zero
            end
        end

        terminates
    end

    class SecondTestTask < Roby::Task
        refine_running_state :namespace => 'test' do
            on :firstly do 
                transition [:running] => :first
            end 

            on :secondly do
                transition [:first] => :second
            end
        end

        terminates
    end

    class DerivedTask < TestTask
        refine_running_state do
            on :four do
                transition [:three] => :four
            end
        end

        terminates
    end

    class ExceptionTask < Roby::Task
        refine_running_state do
            state(:exception) do
                def poll(task)
                    raise ArgumentError
                end
            end
        end
    end

    def setup
        super
        Roby.app.filter_backtraces = false
        @testTask = TestTask.new
    end


    def test_responds_to_state_machine
        assert( @testTask.respond_to?("state_machine") )
    end

    def test_responds_to_state_machine_status
        assert( @testTask.state_machine.status )
    end
      
    def test_has_initial_state_running 
        assert( @testTask.state_machine.status == 'running')
    end

    def test_has_states
        all_states = @testTask.state_machine.states
        check_states = [ :zero, :one, :two, :three ]
        check_states.each do |state|
            assert( all_states.index(state) >= 0 )
        end
    end

    def test_check_multiple_instances
        oneTask = TestTask.new
        twoTask = TestTask.new
        scndTask = SecondTestTask.new
	
        oneTask.state_machine.one!
        assert(oneTask.state_machine.status == 'one')
        assert(twoTask.state_machine.status == 'running')
        assert(scndTask.state_machine.status == 'running')
        
        scndTask.state_machine.firstly!
        assert(oneTask.state_machine.status == 'one')
        assert(twoTask.state_machine.status == 'running')
        assert(scndTask.state_machine.status == 'first')
    end

    def test_automatically_created_new_events
        model = Roby::Task.new_submodel do
            terminates
            refine_running_state do
                on(:intermediate) { transition :running => :one }
            end
        end
        assert model.event_model(:intermediate).controlable?

        task = prepare_plan :add => 1, :model => model
        task.start!
        assert_equal 'running', task.state_machine.status
        task.intermediate!
        assert_equal 'one', task.state_machine.status

        task = prepare_plan :add => 1, :model => model
        task.start!
        assert_equal 'running', task.state_machine.status
        task.emit :intermediate
        assert_equal 'one', task.state_machine.status
    end

    def test_does_not_override_existing_events
        model = Roby::Task.new_submodel do
            terminates
            event :intermediate
            refine_running_state do
                on(:intermediate) { transition :running => :one }
            end
        end
        assert !model.event_model(:intermediate).controlable?

        task = prepare_plan :add => 1, :model => model
        task.start!
        assert_equal 'running', task.state_machine.status
        task.emit :intermediate
        assert_equal 'one', task.state_machine.status
    end

    def test_inheritance
	derivedTask = DerivedTask.new
	assert(derivedTask.state_machine.proxy.respond_to?(:one))
	assert(derivedTask.state_machine.proxy.respond_to?(:two))
	assert(derivedTask.state_machine.proxy.respond_to?(:three))
	assert(derivedTask.state_machine.proxy.respond_to?(:reset))
	assert(derivedTask.state_machine.proxy.respond_to?(:four))
      
        event = [ :one, :two, :three, :four, :reset ] 
	begin
	    event.each do |event|
                derivedTask.state_machine.send("#{event}!")
            end
	rescue Exception => e
	    flunk("Calling event '#{event} failed")
	end
    end

    def test_exception
        task = ExceptionTask.new
        task.state_machine.status = 'exception'
        assert(task.state_machine.respond_to?(:do_poll))

        assert_raises(ArgumentError) do
            task.state_machine.do_poll(task)
        end
    end

    def test_has_no_interaction_with_regular_poll
        mock = flexmock
        mock.should_receive(:poll_called).at_least.once
        mock.should_receive(:one_called).at_least.once

        model = Roby::Task.new_submodel do
            terminates
            event :intermediate

            poll do
                mock.poll_called
            end

            refine_running_state do
                state :running do
                    define_method(:poll) do |task|
                        mock.one_called
                    end
                end
            end
        end

        task = prepare_plan :permanent => 1, :model => model
        task.start!
        process_events
    end

    def test_poll_in_state
        mock = flexmock
        mock.should_receive(:running_poll).once.ordered
        mock.should_receive(:running_poll_event).once.ordered
        mock.should_receive(:one_poll).once.ordered
        mock.should_receive(:one_poll_event).once.ordered

        model = Roby::Task.new_submodel do
            terminates
            event :intermediate
            event :running_poll
            event :one_poll

            refine_running_state do
                poll_in_state :running do |task|
                    mock.running_poll
                    task.emit :running_poll
                end
                on(:intermediate) { transition :running => :one }
                poll_in_state :one do |task|
                    mock.one_poll
                    task.emit :one_poll
                end
                on(:one_poll) { transition :one => :final }
            end
        end

        task = prepare_plan :missions => 1, :model => model
        task.on(:running_poll) { |_| mock.running_poll_event }
        task.start!
        task.on(:one_poll) { |_| mock.one_poll_event }
        task.emit :intermediate
        process_events
    end

    def test_script_in_state
        mock = flexmock
        mock.should_receive(:running_poll).at_least.once
        mock.should_receive(:running_poll_event).at_least.once
        mock.should_receive(:one_poll).at_least.once
        mock.should_receive(:one_poll_event).at_least.once

        model = Roby::Task.new_submodel do
            terminates
            event :intermediate
            event :running_poll
            event :one_poll

            refine_running_state do
                script_in_state :running do
                    execute { mock.running_poll }
                    emit :running_poll
                end
                on(:intermediate) { transition :running => :one }
                script_in_state :one do
                    execute { mock.one_poll }
                    emit :one_poll
                end
                on(:one_poll) { transition :one => :running }
            end
        end

        task = prepare_plan :permanent => 1, :model => model
        task.start!
        task.on(:running_poll) { |_| mock.running_poll_event }
        process_events
        assert task.running_poll?
        task.emit :intermediate
        task.on(:one_poll) { |_| mock.one_poll_event }
        process_events
        assert task.one_poll?, task.history.map(&:symbol).map(&:to_s).join(", ")

        process_events
        process_events
        assert_equal [:start, :running_poll, :intermediate, :one_poll, :running_poll], task.history.map(&:symbol)
    end
end
