require 'roby/test/self'
require 'roby/tasks/simple'

class TC_Actions_Task < Minitest::Test
    class TaskModel < Roby::Task; end

    attr_reader :iface_m, :task
    def setup
        super

        @iface_m = Actions::Interface.new_submodel do
            describe("the test action").
                returns(TaskModel)
            def test_action
                TaskModel.new
            end
        end
        plan.add(task = iface_m.test_action.as_plan)
        @task = task.planning_task
    end

    def test_it_calls_the_action_and_adds_the_result_to_the_transaction
        flexmock(iface_m).new_instances.
            should_receive(:test_action).once.
            and_return(result_task = TaskModel.new)
        flexmock(Transaction).new_instances.
            should_receive(:add).once.
            with(result_task).pass_thru
        flexmock(Transaction).new_instances.
            should_receive(:add).with(any).pass_thru
        task.start!
    end

    def test_it_commits_the_transaction_if_the_action_is_successful
        flexmock(Transaction).new_instances.
            should_receive(:commit_transaction).once.pass_thru
        task.start!
        assert task.success?
    end

    def test_it_emits_success_if_the_action_is_successful
        task.start!
        assert task.success?
    end

    def test_it_emits_failed_if_the_action_raised
        flexmock(iface_m).new_instances.
            should_receive(:test_action).and_raise(ArgumentError)
        assert_logs_exception_with_backtrace ArgumentError, Roby.logger, :warn
        assert_fatal_exception Roby::PlanningFailedError, failure_point: task.planned_task, tasks: [task.planned_task] do
            task.start!
        end
        assert task.failed?
    end

    def test_it_emits_failed_if_the_transaction_failed_to_commit
        flexmock(Transaction).new_instances.
            should_receive(:commit_transaction).and_raise(ArgumentError)
        assert_logs_exception_with_backtrace ArgumentError, Roby.logger, :warn
        assert_fatal_exception Roby::PlanningFailedError, failure_point: task.planned_task, tasks: [task.planned_task] do
            task.start!
        end
        assert task.failed?
    end

    def test_it_discards_the_transaction_on_failure
        flexmock(iface_m).new_instances.should_receive(:test_action).and_raise(ArgumentError)
        flexmock(Transaction).new_instances.should_receive(:discard_transaction).once.pass_thru
        assert_logs_exception_with_backtrace ArgumentError, Roby.logger, :warn
        assert_fatal_exception Roby::PlanningFailedError, failure_point: task.planned_task, tasks: [task.planned_task] do
            task.start!
        end
        assert task.failed?
        assert !task.transaction.plan, "transaction is neither discarded nor committed"
    end

    def test_it_propagates_the_job_id
        task_m = Roby::Task.new_submodel
        planning_m = Roby::Task.new_submodel
        planning_m.terminates
        planning_m.provides Roby::Interface::Job

        iface_m = Actions::Interface.new_submodel do
            describe("the test action").returns(task_m)
            define_method(:test_action) do
                t = task_m.new
                t.planned_by(planning_m.new)
                t
            end
        end

        plan.add(task = iface_m.test_action.as_plan)
        tracker = task.as_service
        task.planning_task.job_id = 10
        assert_event_emission(task.planning_task.success_event) do
            task.planning_task.start!
        end
        assert_kind_of task_m, tracker.task
        assert_kind_of planning_m, tracker.task.planning_task
        assert_equal 10, tracker.task.planning_task.job_id
    end

    def test_it_does_not_attempt_to_set_the_job_id_of_a_task_which_has_it_set_to_nil
        task_m = Roby::Task.new_submodel
        planning_m = Roby::Task.new_submodel
        planning_m.terminates
        planning_m.provides Roby::Interface::Job

        iface_m = Actions::Interface.new_submodel do
            describe("the test action").returns(task_m)
            define_method(:test_action) do
                t = task_m.new
                t.planned_by(planning_m.new(job_id: nil))
                t
            end
        end

        plan.add(task = iface_m.test_action.as_plan)
        tracker = task.as_service
        task.planning_task.job_id = 10
        assert_event_emission(task.planning_task.success_event) do
            task.planning_task.start!
        end
        assert_nil tracker.task.planning_task.job_id
    end

    def test_it_emits_the_start_event_after_having_created_the_transaction
        flexmock(Transaction).should_receive(:new).and_raise(RuntimeError)
        plan.unmark_mission_task(task.planned_task)
        assert_fatal_exception(Roby::PlanningFailedError, tasks: [task.planned_task], failure_point: task.planned_task) do
            assert_task_fails_to_start(task, CodeError, original_exception: RuntimeError, tasks: [task]) do
                task.start!
            end
        end
    end
end

