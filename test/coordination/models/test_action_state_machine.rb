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
        action_m.action_state_machine(name) do
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

    it "raises if attempting to set two start states" do
        assert_raises(ArgumentError) do
            state_machine('state_machine_action') do
                start(state(Roby::Task))
                start(state(Roby::Task))
            end
        end
    end

    it "defines the 'start_state' argument" do
        state_machine('state_machine_action') do
            start(state(Roby::Task))
        end
        machine = action_m.find_action_by_name('state_machine_action')
        state_arg = machine.arguments.find { |arg| arg.name == 'start_state' }
        assert_equal 'name of the state in which the state machine should start', state_arg.doc
        refute state_arg.required
        assert_nil state_arg.default
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

        it "raises if the event is not active in the source state" do
            assert_raises(Roby::Coordination::Models::EventNotActiveInState) do
                state_machine 'test' do
                    start_state = state start_task
                    monitor = state(monitoring_task)
                    next_state  = state next_task
                    start(start_state)
                    transition(start_state, monitor.success_event, next_state)
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

    it "forwards #find_child to its root" do
        _, machine = state_machine 'test' do
            first = state(start_task(id: 10))
            start(first)
        end
        flexmock(task_m).should_receive(:find_child).explicitly.with('first_state').
            and_return(obj = flexmock)
        assert_equal Roby::Coordination::Models::Child.new(machine.root, 'first_state', obj),
            machine.find_child('first_state')
    end

    describe "event forwarding" do
        attr_reader :state_machine, :start
        before do
            _, @state_machine = @action_m.action_state_machine 'test' do
                start = state(start_task)
                start(start)
            end
            @start = state_machine.find_state_by_name('start')
        end

        describe "Event#forward_to" do
            it "forwards an event to the state machine's root using Event#forward_to" do
                flexmock(state_machine).should_receive(:forward).
                    with(start, start.success_event, state_machine.success_event).once
                start.success_event.forward_to(state_machine.success_event)
            end
            it "raises if the target event is not a root event" do
                monitoring = state_machine.state(action_m.monitoring_task)
                # NOTE: it has to be handled separately from #forward, as we
                # need a root event to know which state machine should be called
                assert_raises(Roby::Coordination::Models::NotRootEvent) do
                    start.success_event.forward_to(monitoring.success_event)
                end
            end
        end

        it "forwards an event in a particular state using the state machine's #forward" do
            monitoring = state_machine.state(action_m.monitoring_task)
            start.depends_on(monitoring)
            state_machine.forward start, monitoring.success_event,
                state_machine.success_event

            assert_equal 1, state_machine.forwards.size
            state, from_event, to_event = state_machine.forwards.first
            assert_equal start, state
            assert_equal monitoring.success_event, from_event
            assert_equal state_machine.root.success_event, to_event
        end
        it "raises if attempting to specify a state that is not a toplevel state" do
            monitoring = state_machine.state(action_m.monitoring_task)
            start.depends_on(monitoring)
            
            assert_raises(Roby::Coordination::Models::NotToplevelState) do
                state_machine.forward monitoring, monitoring.success_event,
                    state_machine.success_event
            end
        end
        it "raises if attempting to specify an event that is not active in the state" do
            monitoring = state_machine.state(action_m.monitoring_task)
            state_machine.transition start.success_event, monitoring
            
            assert_raises(Roby::Coordination::Models::EventNotActiveInState) do
                state_machine.forward start, monitoring.success_event,
                    state_machine.success_event
            end
        end
        it "raises if attempting to forward to a non-root event" do
            monitoring = state_machine.state(action_m.monitoring_task)
            state_machine.transition start.success_event, monitoring
            assert_raises(Roby::Coordination::Models::NotRootEvent) do
                state_machine.forward start.success_event,
                    monitoring.success_event
            end
        end
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

    describe "#rebind" do
        attr_reader :state_machine_action, :action_m, :new_action_m
        before do
            @state_machine_action, _ = @action_m.action_state_machine 'test' do
                start_task = state(self.start_task)
                next_task  = state(self.next_task)
                monitoring_task = state(self.monitoring_task)
                depends_on monitoring_task, role: 'test'

                start(start_task)
                start_task.depends_on monitoring_task, role: 'task_dependency'
                transition start_task, start_task.start_event, next_task
                next_task.success_event.forward_to success_event
            end
            @new_action_m = action_m.new_submodel
        end

        it "rebinds the root" do
            rebound = state_machine_action.rebind(new_action_m).
                coordination_model
            refute_same rebound.root, state_machine_action.coordination_model.root
            assert_same rebound, rebound.root.coordination_model
        end
        it "rebinds action-states" do
            rebound = state_machine_action.rebind(new_action_m).
                coordination_model

            assert_equal new_action_m.start_task,
                rebound.find_state_by_name('start_task').action
            assert_equal new_action_m.next_task,
                rebound.find_state_by_name('next_task').action
        end
        it "rebinds the starting state" do
            rebound = state_machine_action.rebind(new_action_m).
                coordination_model

            assert_equal new_action_m.start_task,
                rebound.starting_state.action
        end
        it "rebinds the transitions" do
            rebound = state_machine_action.rebind(new_action_m).
                coordination_model

            assert_equal 1, rebound.transitions.size
            from, event, to = rebound.transitions[0]
            assert_equal new_action_m.start_task, from.action
            assert_equal new_action_m.start_task, event.task.action
            assert_equal :start, event.symbol
            assert_equal new_action_m.next_task,  to.action
        end
        it "rebinds the machine's own dependencies" do
            rebound = state_machine_action.rebind(new_action_m).
                coordination_model

            assert_equal [[new_action_m.monitoring_task, 'test']],
                rebound.dependencies.map { |task, role| [task.action, role] }
        end
        it "rebinds the state-local dependencies" do
            rebound = state_machine_action.rebind(new_action_m).
                coordination_model

            assert_equal [[new_action_m.monitoring_task, 'task_dependency']],
                rebound.find_state_by_name('start_task').dependencies.
                    map { |task, role| [task.action, role] }
        end
        it "rebinds the forwardings" do
            rebound = state_machine_action.rebind(new_action_m).
                coordination_model

            assert_equal 1, rebound.forwards.size
            source_event, target_event = rebound.forwards.first

            assert_equal [[new_action_m.monitoring_task, 'task_dependency']],
                rebound.find_state_by_name('start_task').dependencies.map { |task, role| [task.action, role] }
        end
    end

    describe "DRoby handling" do
        before do
            task_m = self.task_m
            action_m.action_state_machine 'test' do
                task = state(task_m)
                start task
            end
        end
        it "is droby-marshallable" do
            assert_droby_compatible action_m.test
        end

        describe "when the action is already existing remotely" do
            before do
                @r_interface = droby_transfer(action_m)
            end

            it "returns the existing action" do
                @r_interface.describe 'test'
                @r_interface.action_state_machine 'test' do
                    start state(Roby::Task)
                end
                test = droby_transfer(action_m.test)
                assert_same @r_interface.test.model, test.model
            end

            it "does not break transferring the return type afterwards" do
                # Since the return type is marshalled on the local side, it
                # gets registered on the object manager. The remote side
                # *MUST* register it anyways, or transferring it later fails
                # with a missing object ID.
                #
                # We do the "system test" side: this only cares that the
                # task model can be transferred afterwards
                @r_interface.describe 'test'
                @r_interface.action_state_machine 'test' do
                    start state(Roby::Task)
                end
                return_task_m = action_m.test.model.returned_type
                droby_transfer(action_m.test)
                droby_transfer(return_task_m)
            end

            it "does not break transferring DRoby-identifiable objects used on the arguments" do
                # Since the arguments are marshalled on the local side, any
                # droby-marshallable object gets registered on the object
                # manager. The remote side *MUST* register it anyways, or
                # transferring it later fails with a missing object ID.
                #
                # We do the "system test" side: this only cares that the
                # task model can be transferred afterwards
                test_task_m = Roby::Task.new_submodel
                start_task_m = Roby::Task.new_submodel
                description = action_m.describe("with_arguments").
                    optional_arg('test', 'test', test_task_m)
                action_m.action_state_machine 'with_arguments' do
                    start state(start_task_m)
                end
                @r_interface.describe 'with arguments'
                @r_interface.action_state_machine 'with_arguments' do
                    start state(start_task_m)
                end
                droby_transfer(action_m.with_arguments)
                droby_transfer(test_task_m)
            end
        end
    end
end
