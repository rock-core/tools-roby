require 'roby/test/self'
require 'roby/tasks/simple'

module Roby
    module TaskStructure
        describe Conflicts do
            attr_reader :task_m_1, :task_m_2
            before do
                @task_m_1 = Tasks::Simple.new_submodel
                @task_m_2 = Tasks::Simple.new_submodel
            end

            describe "model-level API" do
                it "allows to declare conflicts between instances of two models" do
                    task_m_1.conflicts_with task_m_2
                    assert task_m_1.conflicts_with?(task_m_2)
                end

                it "it is commutative" do
                    task_m_1.conflicts_with task_m_2
                    assert task_m_2.conflicts_with?(task_m_1)
                end

                it "returns false between models that have no relations" do
                    refute task_m_1.conflicts_with?(task_m_2)
                end
            end

            describe "runtime handling" do
                attr_reader :task_1, :task_2
                before do
                    task_m_1.conflicts_with task_m_2
                    plan.add(@task_1 = task_m_1.new)
                    plan.add(@task_2 = task_m_2.new)
                end

                it "does not add conflicts if the tasks are pending" do
                    refute task_1.child_object?(task_2, Roby::TaskStructure::Conflicts)
                    refute task_2.child_object?(task_1, Roby::TaskStructure::Conflicts)
                end
                it "marks in the conflict graph the tasks that cannot start due to a started task" do
                    execute { task_1.start! }
                    refute task_1.child_object?(task_2, Roby::TaskStructure::Conflicts)
                    assert task_2.child_object?(task_1, Roby::TaskStructure::Conflicts)
                end
                it "fails a conflicting task that attempts to start" do
                    execute { task_1.start! }
                    expect_execution { task_2.start! }.
                        to do
                            have_error_matching CommandRejected.match.with_origin(task_2.start_event)
                            fail_to_start task_2, reason: ConflictError
                        end
                end
            end
        end
    end
end
