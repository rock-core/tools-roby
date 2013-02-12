$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/actions'
require 'flexmock/test_unit'

class TC_Actions_StateMachine < Test::Unit::TestCase
    include Roby::Planning
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

    attr_reader :task_m, :action_m, :description
    def setup
        super
        task_m = @task_m = Roby::Task.new_submodel do
            terminates
        end
        description = nil
        @action_m = Actions::Interface.new_submodel do
            describe("the start task").optional_arg(:id, "the task ID")
            define_method(:start_task) { |arg| task_m.new(:id => (arg[:id] || :start)) }
            describe("the next task")
            define_method(:next_task) { task_m.new(:id => :next) }
            describe("a monitoring task")
            define_method(:monitoring_task) { task_m.new(:id => 'monitoring') }
            description = describe("state machine").returns(task_m)
        end
        @description = description
    end

    def start_machine(action_name, *args)
        task = action_m.find_action_by_name(action_name).instanciate(plan, *args)
        task.start!
        task
    end

    def test_it_defines_an_action_with_the_state_machine_name
        action_m.state_machine('state_machine_action') { }
        assert action_m.find_action_by_name('state_machine_action')
    end

    def test_it_starts_the_start_task_when_the_root_task_is_started
        action_m.state_machine 'test' do
            start(start_task)
        end

        task = start_machine('test')
        start = task.current_state_child
        assert_kind_of task_m, start
        assert_equal Hash[:id => :start], start.arguments
    end

    def test_it_can_transition_using_an_arbitrary_event
        action_m.state_machine 'test' do
            monitor = depends_on monitoring_task
            start_state = start_task
            next_state  = next_task
            start(start_state)
            transition(start_state, monitor.success_event, next_state)
        end

        task = start_machine('test')
        monitor = plan.find_tasks.with_arguments(:id => 'monitoring').first
        monitor.start!
        monitor.emit :success
        assert_equal Hash[:id => :next], task.current_state_child.arguments
    end

    def test_it_removes_during_transition_the_dependency_from_the_root_to_the_instanciated_tasks
        action_m.state_machine 'test' do
            monitor = depends_on monitoring_task, :role => 'monitor'
            start_state = start_task
            next_state  = next_task
            start(start_state)
            transition(start_state, monitor.start_event, next_state)
        end
        task = start_machine('test')
        assert_equal Hash[:id => :start], task.current_state_child.arguments
        assert_equal 2, task.children.to_a.size
        assert_equal([task.current_state_child, task.monitor_child].to_set, task.children.to_set)
    end

    def test_it_applies_a_transition_only_for_the_state_it_is_defined_in
        action_m.state_machine 'test' do
            monitor = depends_on monitoring_task, :role => 'monitor'
            start_state = start_task
            next_state  = next_task
            start(start_state)
            transition(next_state, monitor.start_event, start_state)
            transition(start_state, monitor.success_event, next_state)
        end

        task = start_machine('test')
        assert_equal Hash[:id => :start], task.current_state_child.arguments
        task.monitor_child.start!
        assert_equal Hash[:id => :start], task.current_state_child.arguments
        task.monitor_child.emit :success
        assert_equal Hash[:id => :next], task.current_state_child.arguments
        task.monitor_child.start!
        assert_equal Hash[:id => :start], task.current_state_child.arguments
    end


    def test_it_can_forward_events_from_child_to_parent
        task_m.event :next_is_done
        action_m.state_machine 'test' do
            start_state = start_task
            next_state  = next_task
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
        action_m.state_machine 'test' do
            start(start_task)
        end

        task = start_machine('test')
        task.current_state_child.start!
        inhibit_fatal_messages do
            assert_raises(ChildFailedError) { task.current_state_child.emit :success }
        end
        plan.remove_object(task.children.first)
    end

    def test_it_passes_given_arguments_to_the_state_machine_block
        description.required_arg(:task_id, "the task ID")
        action_m.state_machine 'test' do
            start(start_task(:id => task_id))
        end

        task = start_machine('test', :task_id => 10)
        assert_equal 10, task.current_state_child.arguments[:id]
    end

    def test_it_raises_if_an_unknown_argument_is_accessed
        assert_raises(NameError) do
            action_m.state_machine 'test' do
                start(start_task(:id => task_id))
            end
        end
    end

    def test_arbitrary_objects_must_be_converted_using_make_state_first
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
                    state = make(obj)
                    start(state)
                end
            end
        end
    end

    def test_it_can_handle_variables_as_state_definitions
        task_m = self.task_m

        description.required_arg(:first_task, 'the first state')
        action_m.state_machine('test') do
            first_state = make(first_task)
            start(first_state)
        end

        obj = flexmock
        obj.should_receive(:instanciate).and_return(first_task = Roby::Task.new)
        task = start_machine('test', :first_task => obj)
        assert_equal first_task, task.current_state_child
    end

    def test_it_rebinds_the_action_states_to_the_actual_interface_model
        task_m = self.task_m

        child_m = action_m.new_submodel
        flexmock(Actions::ActionModel).new_instances.
            should_receive(:run).once.
            with(child_m, any).pass_thru
        action_m.state_machine('test') do
            start(start_task)
        end

        task = child_m.find_action_by_name('test').instanciate(plan)
        task.start!
        assert task.current_state_child
    end
end

