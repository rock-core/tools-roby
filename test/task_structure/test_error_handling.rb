# frozen_string_literal: true

require "roby/test/self"

module Roby
    module TaskStructure
        describe ErrorHandling do
            describe "#handle_with" do
                attr_reader :task_m, :repair_task, :localized_error_m
                before do
                    @task_m = Task.new_submodel
                    plan.add(@repair_task = task_m.new)
                    @localized_error_m = Class.new(LocalizedError)
                end

                it "sets up the given task as handling any exception whose origin is the event" do
                    plan.add(task = task_m.new)
                    task.start_event.handle_with(repair_task)
                    matcher = task[repair_task, ErrorHandling].first
                    assert(matcher === localized_error_m.new(task.start_event))
                    refute(matcher === localized_error_m.new(task))
                    refute(matcher === localized_error_m.new(task.stop_event))
                end

                it "sets up the event match to use event generalization" do
                    plan.add(task = task_m.new)
                    task.stop_event.handle_with(repair_task)
                    matcher = task[repair_task, ErrorHandling].first
                    assert(matcher === localized_error_m.new(task.failed_event))
                end
            end

            describe "the remove_when_done flag" do
                attr_reader :task, :repair_task

                before do
                    plan.add(@task = Tasks::Simple.new)
                    plan.add(@repair_task = Tasks::Simple.new)
                    execute do
                        task.start!
                        repair_task.start!
                    end
                end

                it "removes the relation when the repairing task is finished if the flag is true" do
                    task.start_event.handle_with(repair_task, remove_when_done: true)
                    execute { repair_task.stop! }
                    assert !task.child_object?(repair_task, ErrorHandling)
                end
                it "keeps the relation even if the repairing task is finished if the flag is false" do
                    task.start_event.handle_with(repair_task, remove_when_done: false)
                    execute { repair_task.stop! }
                    assert task.child_object?(repair_task, ErrorHandling)
                end
                it "ignores an already finalized task" do
                    task.start_event.handle_with(repair_task, remove_when_done: true)
                    execute { task.stop! }
                    execute do
                        plan.remove_task(task)
                        repair_task.stop!
                    end
                end
            end

            describe "#find_all_matching_repair_tasks" do
                attr_reader :task_m, :task, :localized_error_m
                before do
                    @task_m = Task.new_submodel
                    task_m.terminates
                    plan.add(@task = task_m.new)
                    @localized_error_m = Class.new(LocalizedError)
                end

                it "returns an empty array if there are no repair tasks at all" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    assert_equal [], task.find_all_matching_repair_tasks(task_e)
                end
                it "returns an empty array if there are repair tasks, but for matching the exception" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    matcher = flexmock
                    task.add_error_handler(repair_task = task_m.new, Set[matcher])
                    matcher.should_receive(:===).once.with(task_e).and_return(false)
                    assert_equal [], task.find_all_matching_repair_tasks(task_e)
                end
                it "returns the repair task matching the argument" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    matcher = flexmock
                    task.add_error_handler(repair_task = task_m.new, Set[matcher])
                    matcher.should_receive(:===).once.with(task_e).and_return(true)
                    assert_equal [repair_task], task.find_all_matching_repair_tasks(task_e)
                end
            end

            describe "#can_repair_error?" do
                attr_reader :task_m, :task, :repair_task, :localized_error_m
                before do
                    @task_m = Task.new_submodel
                    task_m.terminates
                    plan.add(@task = task_m.new)
                    plan.add(@repair_task = task_m.new)
                    @localized_error_m = Class.new(LocalizedError)
                end

                it "returns false if the task is not repairing anything" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    refute repair_task.can_repair_error?(task_e)
                end
                it "returns false if it is repairing another exception" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    matcher = flexmock
                    task.add_error_handler(repair_task, Set[matcher])
                    matcher.should_receive(:===).once.with(task_e).and_return(false)
                    refute repair_task.can_repair_error?(task_e)
                end
                it "returns false if it is finished" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    matcher = flexmock
                    task.add_error_handler(repair_task, Set[matcher])
                    matcher.should_receive(:===).with(task_e).and_return(true)
                    FlexMock.use(repair_task) do |mock|
                        mock.should_receive(:finished?).once.and_return(true)
                        refute repair_task.can_repair_error?(task_e)
                    end
                end
                it "returns true if it is repairing the given exception" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    matcher = flexmock
                    task.add_error_handler(repair_task, Set[matcher])
                    matcher.should_receive(:===).once.with(task_e).and_return(true)
                    assert repair_task.can_repair_error?(task_e)
                end
            end

            describe "#repairs_error?" do
                attr_reader :task_m, :task, :repair_task, :localized_error_m
                before do
                    @task_m = Task.new_submodel
                    task_m.terminates
                    plan.add(@task = task_m.new)
                    plan.add(@repair_task = task_m.new)
                    @localized_error_m = Class.new(LocalizedError)
                end

                it "returns false if the task is not repairing anything" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    refute repair_task.repairs_error?(task_e)
                end
                it "returns false if it is repairing another exception" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    matcher = flexmock
                    task.add_error_handler(repair_task, Set[matcher])
                    execute { repair_task.start! }
                    matcher.should_receive(:===).once.with(task_e).and_return(false)
                    refute repair_task.repairs_error?(task_e)
                end
                it "returns false if it can repair the exception but it's not running" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    matcher = flexmock
                    task.add_error_handler(repair_task, Set[matcher])
                    matcher.should_receive(:===).with(task_e).and_return(true)
                    refute repair_task.repairs_error?(task_e)
                end
                it "returns true if there is a repair task and it is running" do
                    task_e = localized_error_m.new(task.start_event).to_execution_exception
                    matcher = flexmock
                    task.add_error_handler(repair_task, Set[matcher])
                    matcher.should_receive(:===).once.with(task_e).and_return(true)
                    execute { repair_task.start! }
                    assert repair_task.repairs_error?(task_e)
                end
            end
        end
    end
end
