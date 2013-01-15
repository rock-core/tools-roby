$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/actions'
require 'flexmock/test_unit'

class TC_Actions_StateMachine < Test::Unit::TestCase
    include Roby::Planning
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

    attr_reader :task_m, :action_m
    def setup
        super
        task_m = @task_m = Class.new(Roby::Task) do
            terminates
        end
        @action_m = Class.new(Actions::Interface) do
            describe("the start task")
            define_method(:start_task) { task_m.new(:id => :start) }
            describe("the next task")
            define_method(:next_task) { task_m.new(:id => :next) }
            describe("state machine").returns(task_m)
        end
    end

    def start_machine(action_name)
        task = action_m.find_action_by_name(action_name).instanciate(plan)
        task.start!
        task
    end

    def test_it_starts_the_start_task_when_the_root_task_is_started
        action_m.state_machine 'test' do
            start(start_task)
        end

        task = start_machine('test')
        start = task.start_task_child
        assert_kind_of task_m, start
        assert_equal Hash[:id => :start], start.arguments
    end

    def test_it_can_transition_from_a_task_to_another
        action_m.state_machine 'test' do
            start_state = start_task
            next_state  = next_task
            start(start_state)
            transition(start_state.success_event, next_state)
        end

        task = start_machine('test')
        task.start_task_child.start!
        task.start_task_child.emit :success
        assert_equal Hash[:id => :next], task.next_task_child.arguments
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
        task.start_task_child.start!
        inhibit_fatal_messages do
            assert_raises(ChildFailedError) { task.start_task_child.emit :success }
        end
        plan.remove_object(task.children.first)
    end
end

