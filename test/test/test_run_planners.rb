# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Test
        describe RunPlanners do
            before do
                task_m = @task_m = Roby::Task.new_submodel { terminates }
                planned_tasks = @planned_tasks = [task_m.new, task_m.new]
                @action_m = Roby::Actions::Interface.new_submodel do
                    describe("the test action").optional_arg(:id, "", 0).returns(task_m)
                    define_method :test_action do |id: 0|
                        planned_tasks[id]
                    end
                    describe("the action for children").returns(task_m)
                    define_method :test_child do
                        task_m.new
                    end
                    describe("an action that raises").returns(task_m)
                    define_method :test_action_with_error do
                        raise "some error"
                    end
                    describe("an action that adds a new planner").returns(task_m)
                    define_method :test_action_with_child do
                        planned_tasks[0].depends_on(
                            self.class.test_child.as_plan, role: "test"
                        )
                        planned_tasks[0]
                    end
                end
            end

            after do
                RunPlanners.deregister_planning_handler(@handler_class) if @handler_class
            end

            it "raises right away if the argument is not a task and cannot be converted "\
               "to one" do
                obj = flexmock
                e = assert_raises(ArgumentError) do
                    run_planners(obj)
                end
                assert_equal "#{obj} is not a Roby task and cannot be converted to one",
                             e.message
            end

            it "calls the handler's start and finished? methods under propagation" do
                @handler_class = Class.new(RunPlanners::PlanningHandler) do
                    def start(tasks)
                        tasks.each { |t| t.abstract = false }
                        @@end_propagation = false
                        @@start_propagation =
                            @test.plan.execution_engine.in_propagation_context?
                    end

                    @@called = false

                    def self.valid?
                        @@end_propagation && @@start_propagation
                    end

                    def finished?
                        @@end_propagation =
                            @test.plan.execution_engine.in_propagation_context?
                    end
                end

                RunPlanners.roby_plan_with(@task_m.match.abstract, @handler_class)
                plan.add(root_task = @action_m.test_action.as_plan)
                run_planners(root_task)
                assert @handler_class.valid?
            end

            it "calls a handler with all tasks except those whose planning failed, "\
               "but processes only the ones returned by #filter_tasks" do
                @handler_class = Class.new(RunPlanners::PlanningHandler) do
                    def filter_tasks(tasks)
                        if defined? @@tasks
                            []
                        else
                            @@tasks = tasks
                        end
                    end

                    def start(tasks)
                        raise "unexpected tasks" if @@tasks != tasks
                    end

                    def self.tasks
                        @@tasks
                    end

                    def finished?
                        true
                    end
                end

                planning_task_m = Roby::Task.new_submodel { terminates }

                RunPlanners.roby_plan_with(@task_m.match, @handler_class)
                tasks = 3.times.map do |i|
                    plan.add(t = @task_m.new)
                    t.planned_by(planning_task_m.new)
                    t
                end
                execute do
                    tasks[0].planning_task.start!
                    tasks[1].planning_task.start!
                end

                expect_execution do
                    tasks[0].planning_task.failed_event.emit
                    tasks[1].planning_task.success_event.emit
                end.to { have_error_matching Roby::PlanningFailedError }
                tasks[1].abstract = false

                run_planners(tasks)
                assert_equal 2, @handler_class.tasks.size
                assert_equal tasks[1, 2].to_set,
                             @handler_class.tasks.to_set
            end

            it "handles being given an object instead of an array" do
                plan.add(root_task = @action_m.test_action(id: 0).as_plan)
                assert_equal @planned_tasks[0], run_planners(
                    root_task, recursive: false
                )
            end

            describe "recursive: false" do
                it "runs the planner of the toplevel tasks and "\
                   "returns the planned task" do
                    plan.add(root_task1 = @action_m.test_action(id: 0).as_plan)
                    plan.add(root_task2 = @action_m.test_action(id: 1).as_plan)
                    assert_equal @planned_tasks, run_planners(
                        [root_task1, root_task2], recursive: false
                    )
                end

                it "does not run existing planners in the hierarchy" do
                    plan.add(root_task = @action_m.test_action.as_plan)
                    root_task.depends_on(child = @action_m.test_child.as_plan)
                    run_planners([root_task], recursive: false)
                    assert child.abstract?
                end

                it "does not run planners added by the action" do
                    plan.add(root_task = @action_m.test_action_with_child.as_plan)
                    root_task = run_planners([root_task], recursive: false)
                    assert root_task.first.test_child.abstract?
                end

                it "can be executed in expect_execution context as well" do
                    service = nil
                    expect_execution do
                        plan.add(root_task = @action_m.test_action.as_plan)
                        service = run_planners([root_task])
                    end.to_run
                    assert_equal @planned_tasks[0], service.first.to_task
                end
            end

            describe "recursive: true" do
                it "runs the planner of all tasks that require "\
                   "it in the root task's subplan" do
                    plan.add(root_task1 = @action_m.test_action(id: 0).as_plan)
                    plan.add(root_task2 = @action_m.test_action(id: 1).as_plan)
                    root_task1.depends_on(child = @action_m.test_child.as_plan)
                    child_planner = child.planning_task

                    result = run_planners([root_task1, root_task2], recursive: true)
                    assert_equal @planned_tasks, result
                    assert child_planner.finished?
                end

                it "re-runs planners that have been added in the first pass" do
                    plan.add(root_task = @action_m.test_action_with_child.as_plan)
                    root_task = run_planners(root_task, recursive: true)
                    refute root_task.test_child.abstract?
                end

                it "ignores tasks that have failed planning" do
                    # NOTE: since all of this is done under execution context,
                    # the execution_expectation harness *will* report the
                    # unexpected error. What we want is that the run_planners
                    # continue functioning in these conditions
                    plan.add(root_task = @action_m.test_action_with_error.as_plan)
                    assert_raises(ExecutionExpectations::UnexpectedErrors) do
                        run_planners(root_task, recursive: true)
                    end
                end

                it "reacts to failures in a way that is compatible with "\
                   "the expectations" do
                    # NOTE: since all of this is done under execution context,
                    # the execution_expectation harness *will* report the
                    # unexpected error. What we want is that the run_planners
                    # continue functioning in these conditions
                    plan.add(root_task = @action_m.test_action_with_error.as_plan)
                    expect_execution { run_planners(root_task, recursive: true) }
                        .to { have_error_matching PlanningFailedError.match }
                end
            end
        end
    end
end
