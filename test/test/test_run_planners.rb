# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Test
        describe RunPlanners do
            before do
                task_m = @task_m = Roby::Task.new_submodel { terminates }
                planned_task = @planned_task = task_m.new
                @action_m = Roby::Actions::Interface.new_submodel do
                    describe("the test action").returns(task_m)
                    define_method :test_action do
                        planned_task
                    end
                    describe("the action for children").returns(task_m)
                    define_method :test_child do
                        task_m.new
                    end
                    describe("an action that adds a new planner").returns(task_m)
                    define_method :test_action_with_child do
                        planned_task.depends_on(
                            self.class.test_child.as_plan, role: "test"
                        )
                        planned_task
                    end
                end
            end

            after do
                RunPlanners.deregister_planning_handler(@handler_class) if @handler_class
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

            describe "recursive: false" do
                it "runs the planner of the toplevel task and returns the planned task" do
                    plan.add(root_task = @action_m.test_action.as_plan)
                    assert_equal @planned_task, run_planners(root_task, recursive: false)
                end

                it "does not run existing planners in the hierarchy" do
                    plan.add(root_task = @action_m.test_action.as_plan)
                    root_task.depends_on(child = @action_m.test_child.as_plan)
                    run_planners(root_task, recursive: false)
                    assert child.abstract?
                end

                it "does not run planners added by the action" do
                    plan.add(root_task = @action_m.test_action_with_child.as_plan)
                    root_task = run_planners(root_task, recursive: false)
                    assert root_task.test_child.abstract?
                end

                it "can be executed in expect_execution context as well" do
                    service = nil
                    expect_execution do
                        plan.add(root_task = @action_m.test_action.as_plan)
                        service = run_planners(root_task)
                    end.to_run
                    assert_equal @planned_task, service.to_task
                end
            end
            describe "recursive: true" do
                it "runs the planner of all tasks that require "\
                   "it in the root task's subplan" do
                    plan.add(root_task = @action_m.test_action.as_plan)
                    root_task.depends_on(child = @action_m.test_child.as_plan)
                    child_planner = child.planning_task

                    run_planners(root_task, recursive: true)
                    assert child_planner.finished?
                end
                it "re-runs planners that have been added in the first pass" do
                    plan.add(root_task = @action_m.test_action_with_child.as_plan)
                    root_task = run_planners(root_task, recursive: true)
                    refute root_task.test_child.abstract?
                end
            end
        end
    end
end
