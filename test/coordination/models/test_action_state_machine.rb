require 'roby/test/self'

describe Roby::Coordination::Models::ActionStateMachine do
    attr_reader :task_m, :action_m, :description
    before do
        task_m = @task_m = Roby::Task.new_submodel(name: 'TaskModel') do
            terminates
        end
        description = nil
        @action_m = Roby::Actions::Interface.new_submodel do
            describe("the start task").returns(task_m).optional_arg(:id, "the task ID")
            define_method(:start_task) { |arg| task_m.new(id: (arg[:id] || :start)) }
            describe("the next task").returns(task_m)
            define_method(:next_task) { task_m.new(id: :next) }
            describe("a monitoring task").returns(task_m)
            define_method(:monitoring_task) { task_m.new(id: 'monitoring') }
            description = describe("state machine").returns(task_m)
        end
        @description = description
    end

    def start_machine(action_name, *args)
        task = action_m.find_action_by_name(action_name).instanciate(plan, *args)
        plan.add_permanent_task(task)
        task.start!
        task
    end

    def state_machine(name, &block)
        action_m.state_machine(name) do
            def start_task(task)
                tasks = super
                tasks.each do |t|
                    t.planning_task.start!
                end
                tasks
            end
            class_eval(&block)
        end
    end

    it "defines an action whose name is the state machine name" do
        state_machine('state_machine_action') do
            start(state(Roby::Task))
        end
        assert action_m.find_action_by_name('state_machine_action')
    end

    describe "#transition" do
        it "raises if the source state if not reachable" do
            assert_raises(Roby::Coordination::Models::UnreachableStateUsed) do
                state_machine 'test' do
                    start_state = state start_task
                    start_state.depends_on(monitor = state(monitoring_task))
                    next_state  = state next_task
                    start(start_state)
                    transition(monitor.success_event, next_state)
                end
            end
        end
    end

    it "assigns the name of the local variable, suffixed with _suffix, to the state name" do
        _, machine = state_machine 'test' do
            first = state(start_task(id: 10))
            start(first)
        end
        assert_equal 'first_state', machine.tasks.first.name
    end

    it "can resolve a state model by its child name" do
        _, machine = state_machine 'test' do
            first = state(start_task(id: 10))
            start(first)
        end
        assert_equal task_m, machine.find_child('first_state')
    end

    describe "validation" do
        it "raises ArgumentError if a plain task is used as a state" do
            obj = flexmock
            obj.should_receive(:to_action_state)
            task_m = self.task_m
            assert_raises(ArgumentError) do
                Roby::Actions::Interface.new_submodel do
                    describe('state machine').
                        required_arg(:first_state, 'the first state').
                        returns(task_m)
                    state_machine('test') do
                        start(obj)
                    end
                end
            end
        end

        it "raises if an unknown argument is accessed" do
            assert_raises(NameError) do
                state_machine 'test' do
                    start(state(start_task(id: task_id)))
                end
            end
        end
    end

    describe "#state" do
        it "can use any object that responds to #to_action_state" do
            obj = flexmock
            obj.should_receive(:to_action_state).and_return(task = Roby::Task.new)
            task_m = self.task_m
            assert_raises(ArgumentError) do
                Roby::Actions::Interface.new_submodel do
                    describe('state machine').
                        required_arg(:first_state, 'the first state').
                        returns(task_m)
                    state_machine('test') do
                        state = state(obj)
                        start(state)
                    end
                end
            end
        end
    end
end

