# frozen_string_literal: true

require "roby/test/self"

module Roby
    module TaskStructure
        describe PlannedBy do
            describe "#planned_by" do
                it "raises ArgumentError if the receiver already has a planner" do
                    task, p1, p2 = prepare_plan add: 3
                    task.planned_by p1
                    assert_raises(ArgumentError) { task.planned_by p2 }
                    assert task.child_object?(p1, PlannedBy)
                    refute task.child_object?(p2, PlannedBy)
                end

                it "replaces the old planner by the new if the replace option is true" do
                    task, p1, p2 = prepare_plan add: 3
                    task.planned_by p1
                    task.planned_by p2, replace: true
                    refute task.child_object?(p1, PlannedBy)
                    assert task.child_object?(p2, PlannedBy)
                end
            end

            describe "structure check" do
                attr_reader :task, :planner

                before do
                    plan.add(@task = Roby::Task.new)
                    task.planned_by(@planner = Roby::Test::Tasks::Simple.new)
                end

                it "does not generate any error if both tasks are pending" do
                    assert_equal([], plan.check_structure.to_a)
                end

                it "does not generate any error if the planner is running" do
                    execute { planner.start! }
                    assert_equal([], plan.check_structure.to_a)
                end

                it "does not generate any error if the planner has successfully finished" do
                    execute do
                        planner.start!
                        planner.success!
                    end
                    assert_equal([], plan.check_structure.to_a)
                end

                it "generates a PlanningFailedError error localized on the planned task if the planner fails" do
                    execute { planner.start! }
                    error = expect_execution { planner.failed! }
                        .to { have_error_matching PlanningFailedError.match.with_origin(task) }
                        .exception
                    assert_equal planner, error.planning_task
                    assert_equal task, error.planned_task
                end

                # Regression check related to #check_structure not returning the
                # right propagation information. See ac428a1b61375275ee4dd3e53127f748325b9eab
                it "properly propagates planning failed errors on non-toplevel planned tasks" do
                    plan.add(root = Roby::Task.new)
                    task = root.depends_on(Roby::Task.new)
                    planner = task.planned_by(Roby::Test::Tasks::Simple.new)
                    execute { planner.start! }

                    expect_execution { planner.failed! }.to do
                        have_error_matching PlanningFailedError.match.with_origin(task)
                            .to_execution_exception_matcher
                            .with_trace(task => root)
                    end
                end
            end

            it "wraps the planned_task within a transaction on first access" do
                # Note: we only check #planned_task. #planning_task is provided
                # by the single_child support in relations, and tested there.
                plan = Roby::Plan.new
                plan.add(planned_task = Roby::Task.new)
                planned_task.planned_by(planning_task = Roby::Task.new)
                plan.in_transaction do |trsc|
                    assert_equal planned_task, trsc[planning_task]
                        .planned_task.__getobj__
                end
            end

            def test_as_plan
                model = Tasks::Simple.new_submodel
                flexmock(model).should_receive(:as_plan).and_return { model.new(id: 10) }
                root = prepare_plan add: 1, model: Tasks::Simple
                agent = root.planned_by(model)
                assert_kind_of model, agent
                assert_equal 10, agent.arguments[:id]
            end
        end
    end
end
