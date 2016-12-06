require 'roby/test/self'

describe Roby::Coordination::ActionStateMachine do
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

    describe "instanciation" do
        it "passes instanciation arguments to the generated tasks" do
            description.required_arg(:task_id, "the task ID")
            state_machine 'test' do
                start(state(start_task(id: task_id)))
            end

            task = start_machine('test', task_id: 10)
            assert_equal 10, task.current_task_child.arguments[:id]
        end
    end

    it "gets into the start state when the root task is started" do
        state_machine 'test' do
            start = state start_task
            start(start)
        end

        task = start_machine('test')
        start = task.current_task_child
        assert_kind_of task_m, start
        assert_equal Hash[id: :start], start.arguments
    end

    it "starting state can be overridden by passing start_state argument" do
        state_machine 'test' do
            start = state start_task
            second = state next_task
            start(start)
        end

        task = start_machine('test', start_state: "second")
        start = task.current_task_child
        assert_kind_of task_m, start
        assert_equal Hash[id: :next], start.arguments
    end

    it "state_machines check for accidentally given arg \"start_state\"" do
        description.optional_arg("start_state")
        assert_raises(ArgumentError) {
            state_machine 'test' do
                start_state = state start_task
                start(start_state)
            end
        }
    end

    describe "transitions" do
        it "can transition using an event from a globally defined dependency" do
            state_machine 'test' do
                depends_on(monitor = state(monitoring_task))
                start_state = state start_task
                next_state  = state next_task
                start(start_state)
                transition(start_state, monitor.success_event, next_state)
            end

            task = start_machine('test')
            monitor = plan.find_tasks.with_arguments(id: 'monitoring').first
            monitor.start!
            monitor.success_event.emit
            assert_equal Hash[id: :next], task.current_task_child.arguments
        end

        it "can transition using an event from a state-local dependency" do
            state_machine 'test' do
                start_state = state start_task
                start_state.depends_on(monitor = state(monitoring_task))
                next_state  = state next_task
                start(start_state)
                transition(start_state, monitor.success_event, next_state)
            end

            task = start_machine('test')
            monitor = plan.find_tasks.with_arguments(id: 'monitoring').first
            monitor.start!
            monitor.success_event.emit
            assert_equal Hash[id: :next], task.current_task_child.arguments
        end

        it "removes the dependency from the root task to the current state's task" do
            state_machine 'test' do
                monitor = state(monitoring_task)
                depends_on monitor, role: 'monitor'
                start_state = state start_task
                next_state  = state next_task
                start(start_state)
                transition(start_state, monitor.start_event, next_state)
            end
            task = start_machine('test')
            assert_equal Hash[id: :start], task.current_task_child.arguments
            assert_equal 2, task.children.to_a.size
            assert_equal([task.current_task_child, task.monitor_child].to_set, task.children.to_set)
        end

        it "transitions because of an event only in the source state" do
            state_machine 'test' do
                monitor = state monitoring_task
                depends_on monitor, role: 'monitor'
                start_state = state start_task
                next_state  = state next_task
                start(start_state)
                transition(next_state, monitor.start_event, start_state)
                transition(start_state, monitor.success_event, next_state)
            end

            task = start_machine('test')
            assert_equal Hash[id: :start], task.current_task_child.arguments
            task.monitor_child.start!
            assert_equal Hash[id: :start], task.current_task_child.arguments
            task.monitor_child.success_event.emit
            assert_equal Hash[id: :next], task.current_task_child.arguments
            task.monitor_child.start!
            assert_equal Hash[id: :start], task.current_task_child.arguments
        end
    end

    it "applies the declared forwardings" do
        task_m.event :next_is_done
        state_machine 'test' do
            start_state = state start_task
            next_state  = state next_task
            start(start_state)
            transition(start_state.success_event, next_state)
            forward next_state.stop_event, next_is_done_event
            forward next_state.stop_event, success_event
        end

        task = start_machine('test')
        task.children.first.start!
        task.children.first.success_event.emit
        task.children.first.start!
        task.children.first.success_event.emit
        assert task.next_is_done_event.emitted?
    end

    it "sets known transitions and only them as 'success' in the dependency" do
        state_machine 'test' do
            start(state(start_task))
        end

        task = start_machine('test')
        task.current_task_child.start!
        assert_raises(Roby::ChildFailedError) { task.current_task_child.success_event.emit }
        plan.remove_task(task.children.first)
    end

    it "can be passed actual state models as arguments" do
        task_m = self.task_m

        description.required_arg(:first_task, 'the first state')
        state_machine('test') do
            first_state = state(first_task)
            start(first_state)
        end

        task = start_machine('test', first_task: action_m.start_task)
        assert_equal :start, task.current_task_child.arguments[:id]
    end

    it "rebinds the action states to the actual interface model" do
        task_m = self.task_m
        child_task_m = task_m.new_submodel(name: "TaskChildModel")

        child_m = action_m.new_submodel do
            define_method(:start_task) do |arg|
                child_task_m.new(id: (arg[:id] || :start))
            end
        end
        state_machine('test') do
            start(state(start_task))
        end

        task = child_m.find_action_by_name('test').instanciate(plan)
        task.start!
        assert task.current_task_child
        assert_kind_of child_task_m, task.current_task_child
    end

    # NOTE: this should be in a separate test suite for Coordination::Base (!)
    def test_it_can_be_associated_with_fault_response_tables
        task_m = self.task_m
        table_m = Roby::Coordination::FaultResponseTable.new_submodel
        action_m.action_state_machine 'test' do
            use_fault_response_table table_m
            start state(task_m)
        end
        task = action_m.test.instanciate(plan)
        assert plan.active_fault_response_tables.empty?
        task.start!
        table = plan.active_fault_response_tables.first
        assert table
        assert_kind_of table_m, table
        task.stop!
        assert plan.active_fault_response_tables.empty?
    end

    # NOTE: this should be in a separate test suite for Coordination::Base (!)
    def test_it_can_pass_arguments_to_the_associated_fault_response_tables
        task_m = self.task_m
        table_m = Roby::Coordination::FaultResponseTable.new_submodel do
            argument :arg
        end
        description.required_arg('machine_arg')
        action_m.action_state_machine 'test' do
            use_fault_response_table table_m, arg: machine_arg
            start state(task_m)
        end
        task = action_m.test.instanciate(plan, machine_arg: 10)
        task.start!
        table = plan.active_fault_response_tables.first
        assert_equal Hash[arg: 10], table.arguments
    end

    it "does not instanciate transitions if the root task is finished" do
        task_m = self.task_m
        _, state_machine_m = action_m.action_state_machine 'test' do
            task = state(task_m)
            next_task = state(task_m)
            start task
            transition task.success_event, next_task
        end
        plan.add(task = task_m.new)
        state_machine = state_machine_m.new(action_m, task)

        task.start!
        flexmock(state_machine).should_receive(:instanciate_state).never
        plan.add_permanent_task(task.current_task_child)
        task.current_task_child.start!
        task.stop!
        task.current_task_child.success_event.emit
    end

    it "removes forwarding to the root task if it is finished" do
        task_m = self.task_m
        _, state_machine_m = action_m.action_state_machine 'test' do
            task = state(task_m)
            start task
            forward task.success_event, success_event
        end
        plan.add(task = task_m.new)
        state_machine = state_machine_m.new(action_m, task)

        task.start!
        task.current_task_child.start!
        task.stop!
        task.current_task_child.success_event.emit
    end
end

