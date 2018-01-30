require 'roby/test/self'
require 'roby/tasks/simple'
require 'roby/test/tasks/empty_task'

module Roby
    describe TaskStateMachine do
        describe "#poll_in_state" do
            it "does not interact with the regular poll" do
                poll_called, running_state_poll_called = nil
                task_m = Roby::Task.new_submodel do
                    terminates
                    poll { poll_called = true }
                    refine_running_state do
                        poll_in_state :running do |task|
                            running_state_poll_called = true
                        end
                    end
                end

                plan.add(task = task_m.new)
                expect_execution { task.start! }.
                    to { achieve { poll_called && running_state_poll_called } }
            end

            it "is polling in the expected state" do
                running_poll, one_poll = nil
                task_m = Roby::Task.new_submodel do
                    terminates
                    event :intermediate

                    refine_running_state do
                        poll_in_state :running do |task|
                            running_poll = true
                        end
                        on(:intermediate) { transition :running => :one }
                        poll_in_state :one do |task|
                            one_poll = true
                        end
                    end
                end

                plan.add(task = task_m.new)
                expect_execution { task.start! }.
                    to { achieve { running_poll && !one_poll } }
                expect_execution { task.intermediate_event.emit }.
                    to { achieve { one_poll } }
                running_poll = false
                expect_execution.to { achieve { !running_poll && one_poll } }
            end

            it "is passed the task instance" do
                running_task = nil
                task_m = Roby::Task.new_submodel do
                    terminates
                    refine_running_state do
                        poll_in_state :running do |task|
                            running_task = task
                        end
                    end
                end
                plan.add(task = task_m.new)
                yield_task = expect_execution { task.start! }.
                    to { achieve { running_task } }
                assert_equal task, yield_task
            end
        end

        describe "#script_in_state" do
            it "is executed as a task script" do
                running_poll, one_poll = nil
                task_m = Roby::Task.new_submodel do
                    terminates
                    event :intermediate
                    event :running_poll
                    event :one_poll

                    refine_running_state do
                        script_in_state :running do
                            execute { running_poll = true }
                            emit running_poll_event
                        end
                        on(:intermediate) { transition :running => :one }
                        script_in_state :one do
                            execute { one_poll = true }
                            emit one_poll_event
                        end
                        on(:one_poll) { transition :one => :running }
                    end
                end

                plan.add(task = task_m.new)
                expect_execution { task.start! }.
                    to do
                        achieve { running_poll && !one_poll }
                        emit task.running_poll_event
                    end

                running_poll = false
                expect_execution { task.intermediate_event.emit }.
                    to do
                        achieve { !running_poll && one_poll }
                        emit task.one_poll_event
                    end
            end

            it "calls the script repeatedly until the script finishes" do
                running_poll = 0
                task_m = Roby::Task.new_submodel do
                    terminates
                    event :done
                    refine_running_state do
                        script_in_state :running do
                            poll_until(done_event) { running_poll += 1 }
                        end
                    end
                end

                plan.add(task = task_m.new)
                expect_execution { task.start! }.
                    to { achieve { running_poll == 2 } }
                expect_execution { task.done_event.emit }.
                    to { achieve { running_poll <= 3 } }
                expect_execution.
                    to { achieve { running_poll <= 3 } }
            end
        end
    end
end


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
        refine_running_state namespace: 'test' do
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

    def test_state_machine_definition_does_not_leak
        recorder = flexmock
        recorder.should_receive(:called).with(:init1).never

        Task.new_submodel do
            terminates
            refine_running_state do
                poll_in_state :running do |task|
                    recorder.called(:init1)
                end
            end
        end
        m2 = Task.new_submodel do
            terminates
            refine_running_state do
            end
        end
        plan.add(t = m2.new)
        execute { t.start! }
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
        
        scndTask.state_machine.firstly_test!
        assert(oneTask.state_machine.status == 'one')
        assert(twoTask.state_machine.status == 'running')
        assert(scndTask.state_machine.status == 'first')
    end

    def test_automatically_created_new_events
        model = Roby::Task.new_submodel do
            terminates
            refine_running_state do
                on(:intermediate) { transition running: :one }
            end
        end
        assert model.event_model(:intermediate).controlable?

        task = prepare_plan add: 1, model: model
        execute { task.start! }
        assert_equal 'running', task.state_machine.status
        execute { task.intermediate! }
        assert_equal 'one', task.state_machine.status

        task = prepare_plan add: 1, model: model
        execute { task.start! }
        assert_equal 'running', task.state_machine.status
        execute { task.intermediate_event.emit }
        assert_equal 'one', task.state_machine.status
    end

    def test_does_not_override_existing_events
        model = Roby::Task.new_submodel do
            terminates
            event :intermediate
            refine_running_state do
                on(:intermediate) { transition running: :one }
            end
        end
        assert !model.event_model(:intermediate).controlable?

        task = prepare_plan add: 1, model: model
        execute { task.start! }
        assert_equal 'running', task.state_machine.status
        execute { task.intermediate_event.emit }
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

end

