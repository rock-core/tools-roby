$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/self'
require 'roby/actions'
require 'flexmock/test_unit'

class TC_Coordination_ActionStateMachine < Test::Unit::TestCase
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

    attr_reader :task_m, :action_m, :description
    def setup
        super
        task_m = @task_m = Roby::Task.new_submodel(:name => 'TaskModel') do
            terminates
        end
        description = nil
        @action_m = Actions::Interface.new_submodel do
            describe("the start task").returns(task_m).optional_arg(:id, "the task ID")
            define_method(:start_task) { |arg| task_m.new(:id => (arg[:id] || :start)) }
            describe("the next task").returns(task_m)
            define_method(:next_task) { task_m.new(:id => :next) }
            describe("a monitoring task").returns(task_m)
            define_method(:monitoring_task) { task_m.new(:id => 'monitoring') }
            description = describe("state machine").returns(task_m)
        end
        @description = description
    end

    def start_machine(action_name, *args)
        task = action_m.find_action_by_name(action_name).instanciate(plan, *args)
        plan.add_permanent(task)
        task.start!
        task
    end

    def test_it_defines_an_action_with_the_state_machine_name
        state_machine('state_machine_action') do
            start(state(Roby::Task))
        end
        assert action_m.find_action_by_name('state_machine_action')
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

    def test_it_starts_the_start_task_when_the_root_task_is_started
        state_machine 'test' do
            start = state start_task
            start(start)
        end

        task = start_machine('test')
        start = task.current_task_child
        assert_kind_of task_m, start
        assert_equal Hash[:id => :start], start.arguments
    end

    def test_it_can_transition_using_an_event_from_a_globally_defined_dependency
        state_machine 'test' do
            depends_on(monitor = state(monitoring_task))
            start_state = state start_task
            next_state  = state next_task
            start(start_state)
            transition(start_state, monitor.success_event, next_state)
        end

        task = start_machine('test')
        monitor = plan.find_tasks.with_arguments(:id => 'monitoring').first
        monitor.start!
        monitor.emit :success
        assert_equal Hash[:id => :next], task.current_task_child.arguments
    end

    def test_it_can_transition_using_an_event_from_a_task_level_dependency
        state_machine 'test' do
            start_state = state start_task
            start_state.depends_on(monitor = state(monitoring_task))
            next_state  = state next_task
            start(start_state)
            transition(start_state, monitor.success_event, next_state)
        end

        task = start_machine('test')
        monitor = plan.find_tasks.with_arguments(:id => 'monitoring').first
        monitor.start!
        monitor.emit :success
        assert_equal Hash[:id => :next], task.current_task_child.arguments
    end

    def test_it_raises_if_a_transition_source_state_is_not_reachable
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

    def test_it_removes_during_transition_the_dependency_from_the_root_to_the_instanciated_tasks
        state_machine 'test' do
            monitor = state(monitoring_task)
            depends_on monitor, :role => 'monitor'
            start_state = state start_task
            next_state  = state next_task
            start(start_state)
            transition(start_state, monitor.start_event, next_state)
        end
        task = start_machine('test')
        assert_equal Hash[:id => :start], task.current_task_child.arguments
        assert_equal 2, task.children.to_a.size
        assert_equal([task.current_task_child, task.monitor_child].to_set, task.children.to_set)
    end

    def test_it_applies_a_transition_only_for_the_state_it_is_defined_in
        state_machine 'test' do
            monitor = state monitoring_task
            depends_on monitor, :role => 'monitor'
            start_state = state start_task
            next_state  = state next_task
            start(start_state)
            transition(next_state, monitor.start_event, start_state)
            transition(start_state, monitor.success_event, next_state)
        end

        task = start_machine('test')
        assert_equal Hash[:id => :start], task.current_task_child.arguments
        task.monitor_child.start!
        assert_equal Hash[:id => :start], task.current_task_child.arguments
        task.monitor_child.emit :success
        assert_equal Hash[:id => :next], task.current_task_child.arguments
        task.monitor_child.start!
        assert_equal Hash[:id => :start], task.current_task_child.arguments
    end


    def test_it_can_forward_events_from_child_to_parent
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
        task.children.first.emit :success
        task.children.first.start!
        task.children.first.emit :success
        assert task.next_is_done_event.happened?
    end

    def test_it_sets_up_dependencies_based_on_known_transitions
        state_machine 'test' do
            start(state(start_task))
        end

        task = start_machine('test')
        task.current_task_child.start!
        inhibit_fatal_messages do
            assert_raises(ChildFailedError) { task.current_task_child.emit :success }
        end
        plan.remove_object(task.children.first)
    end

    def test_it_passes_given_arguments_to_the_state_machine_block
        description.required_arg(:task_id, "the task ID")
        state_machine 'test' do
            start(state(start_task(:id => task_id)))
        end

        task = start_machine('test', :task_id => 10)
        assert_equal 10, task.current_task_child.arguments[:id]
    end

    def test_it_raises_if_an_unknown_argument_is_accessed
        assert_raises(NameError) do
            state_machine 'test' do
                start(state(start_task(:id => task_id)))
            end
        end
    end

    def test_it_sets_the_task_names_to_the_name_of_the_local_variables_they_are_assigned_to_with_a_state_suffix
        _, machine = state_machine 'test' do
            first = state(start_task(:id => 10))
            start(first)
        end
        assert_equal 'first_state', machine.tasks.first.name
    end

    def test_it_can_resolve_a_state_model_by_its_child_name
        _, machine = state_machine 'test' do
            first = state(start_task(:id => 10))
            start(first)
        end
        assert_equal task_m, machine.find_child('first_state')
    end

    def test_arbitrary_objects_must_be_converted_using_state_first
        obj = flexmock
        obj.should_receive(:to_action_state)
        task_m = self.task_m
        assert_raises(ArgumentError) do
            Actions::Interface.new_submodel do
                describe('state machine').
                    required_arg(:first_state, 'the first state').
                    returns(task_m)
                state_machine('test') do
                    start(obj)
                end
            end
        end
    end

    def test_it_can_use_any_object_responding_to_to_action_state
        obj = flexmock
        obj.should_receive(:to_action_state).and_return(task = Roby::Task.new)
        task_m = self.task_m
        assert_raises(ArgumentError) do
            Actions::Interface.new_submodel do
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

    def test_it_can_handle_variables_as_state_definitions
        task_m = self.task_m

        description.required_arg(:first_task, 'the first state')
        state_machine('test') do
            first_state = state(first_task)
            start(first_state)
        end

        task = start_machine('test', :first_task => action_m.start_task)
        assert_equal :start, task.current_task_child.arguments[:id]
    end

    def test_it_rebinds_the_action_states_to_the_actual_interface_model
        task_m = self.task_m
        child_task_m = task_m.new_submodel(:name => "TaskChildModel")

        child_m = action_m.new_submodel do
            define_method(:start_task) do |arg|
                child_task_m.new(:id => (arg[:id] || :start))
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
            use_fault_response_table table_m, :arg => machine_arg
            start state(task_m)
        end
        task = action_m.test.instanciate(plan, :machine_arg => 10)
        task.start!
        table = plan.active_fault_response_tables.first
        assert_equal Hash[:arg => 10], table.arguments
    end

    def test_it_does_not_instanciates_transitions_if_the_root_task_is_finished
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
        plan.add_permanent(task.current_task_child)
        task.current_task_child.start!
        task.stop!
        task.current_task_child.success_event.emit
    end

    def test_it_removes_forwarding_to_the_root_task_if_it_is_finished
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

