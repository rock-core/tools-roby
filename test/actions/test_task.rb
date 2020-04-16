# frozen_string_literal: true

require "roby/test/self"
require "roby/tasks/simple"

class TC_Actions_Task < Minitest::Test
    class TaskModel < Roby::Task; end

    attr_reader :iface_m, :task
    def setup
        super

        @iface_m = Actions::Interface.new_submodel do
            class_eval do
                describe("the test action")
                    .returns(TaskModel)
                def test_action
                    TaskModel.new
                end
            end
        end
        plan.add(task = iface_m.test_action.as_plan)
        @task = task.planning_task
    end

    def test_it_calls_the_action_and_adds_the_result_to_the_transaction
        flexmock(iface_m).new_instances
            .should_receive(:test_action).once
            .and_return(result_task = TaskModel.new)
        flexmock(Transaction).new_instances
            .should_receive(:add).once
            .with(result_task).pass_thru
        flexmock(Transaction).new_instances
            .should_receive(:add).with(any).pass_thru
        execute { task.start! }
    end

    def test_it_commits_the_transaction_if_the_action_is_successful
        flexmock(Transaction).new_instances
            .should_receive(:commit_transaction).once.pass_thru
        expect_execution { task.start! }
            .to { emit task.success_event }
    end

    def test_it_emits_success_if_the_action_is_successful
        expect_execution { task.start! }
            .to { emit task.success_event }
    end

    def test_it_emits_failed_and_raises_PlanningFailedError_if_the_action_raised
        flexmock(iface_m).new_instances
            .should_receive(:test_action).and_raise(ArgumentError)
        expect_execution { task.start! }.to do
            have_error_matching PlanningFailedError.match.with_origin(task.planned_task)
            emit task.failed_event
        end
    end

    def test_it_emits_failed_if_the_transaction_failed_to_commit
        flexmock(Transaction).new_instances
            .should_receive(:commit_transaction).and_raise(ArgumentError)
        expect_execution { task.start! }.to do
            have_error_matching PlanningFailedError.match.with_origin(task.planned_task)
            emit task.failed_event
        end
    end

    def test_it_discards_the_transaction_on_failure
        flexmock(iface_m).new_instances.should_receive(:test_action).and_raise(ArgumentError)
        flexmock(Transaction).new_instances.should_receive(:discard_transaction).once.pass_thru
        expect_execution { task.start! }.to do
            have_error_matching PlanningFailedError.match.with_origin(task.planned_task)
            emit task.failed_event
        end
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
        expect_execution { task.planning_task.start! }
            .to { emit task.planning_task.success_event }
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
        expect_execution { task.planning_task.start! }
            .to { emit task.planning_task.success_event }
        assert_nil tracker.task.planning_task.job_id
    end

    def test_it_emits_the_start_event_after_having_created_the_transaction
        flexmock(Transaction).should_receive(:new).and_raise(RuntimeError)
        plan.unmark_mission_task(task.planned_task)
        expect_execution { task.start! }
            .to do
                fail_to_start task, reason: CodeError.match.with_origin(task).with_original_exception(RuntimeError)
                have_error_matching PlanningFailedError
            end
    end
end
