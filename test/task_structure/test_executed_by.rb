# frozen_string_literal: true

require "roby/test/self"

module Roby
    module TaskStructure
        describe ExecutionAgent do
            class BaseExecutionAgent < Tasks::Simple
                event :ready
            end
            class ExecutionAgentModel < Tasks::Simple
                event :ready
                forward start: :ready
            end
            class SecondExecutionModel < Tasks::Simple
                event :ready
                forward start: :ready
            end

            def test_relationships
                plan.add(task = Tasks::Simple.new)
                exec_task = ExecutionAgentModel.new

                task.executed_by exec_task
                assert_equal(exec_task, task.execution_agent)
            end

            def test_inherits_execution_model
                model = Roby::Task.new_submodel do
                    executed_by ExecutionAgentModel, id: 20
                end
                submodel = model.new_submodel

                assert_equal([ExecutionAgentModel, { id: 20 }], submodel.execution_agent)
            end

            def test_failure_to_emit_ready_marks_executed_tasks_as_failed_to_start_by_default
                plan.add(task = Roby::Tasks::Simple.new)
                execution_agent = Roby::Tasks::Simple.new_submodel do
                    event :ready
                end.new
                task.executed_by execution_agent
                execute { execution_agent.start! }
                reason = execute do
                    execution_agent.ready_event.unreachable!(reason = flexmock)
                    reason
                end
                assert task.failed_to_start?
                assert_equal reason, task.failure_reason
            end

            def test_what_to_do_when_an_execution_agent_fails_to_start_is_determined_by_the_control_object
                plan.add(task = Roby::Tasks::Simple.new)
                execution_agent = Roby::Tasks::Simple.new_submodel do
                    event :ready
                end.new
                task.executed_by execution_agent

                flexmock(plan.control).should_receive(:execution_agent_failed_to_start)
                    .once

                execute { execution_agent.failed_to_start!(reason = flexmock) }
                refute task.failed_to_start?
            end

            def test_emission_of_stop_marks_pending_executed_tasks_as_failed_to_start_by_default
                plan.add(task = Roby::Tasks::Simple.new)
                execution_agent = Roby::Tasks::Simple.new_submodel do
                    event :ready
                end.new
                task.executed_by execution_agent
                execute do
                    execution_agent.start!
                    execution_agent.ready_event.emit
                end
                execute { execution_agent.stop! }
                assert task.failed_to_start?
                assert_equal execution_agent.failed_event.last, task.failure_reason
            end

            def test_what_to_do_when_an_execution_agent_stops_with_pending_tasks_is_determined_by_the_control_object
                plan.add(task = Roby::Tasks::Simple.new)
                execution_agent = Roby::Tasks::Simple.new_submodel do
                    event :ready
                end.new
                task.executed_by execution_agent

                flexmock(plan.control).should_receive(:pending_executed_by_failed)
                    .once

                execute do
                    execution_agent.start!
                    execution_agent.ready_event.emit
                end
                execute do
                    execution_agent.stop!
                end
                refute task.failed_to_start?
            end

            def test_nominal
                plan.add(task = Tasks::Simple.new)
                task.executed_by(ExecutionAgentModel.new)
                task.executed_by(exec = ExecutionAgentModel.new)

                FlexMock.use do |mock|
                    exec.start_event.on { |ev| mock.agent_started }
                    exec.ready_event.on { |ev| mock.agent_ready }
                    task.start_event.on { |ev| mock.task_started }

                    mock.should_receive(:agent_started).once.ordered
                    mock.should_receive(:agent_ready).once.ordered
                    mock.should_receive(:task_started).once.ordered
                    execute do
                        exec.start!
                        task.start!
                    end
                end
            end

            def test_executed_by_verifies_that_the_agent_has_a_ready_event
                plan.add(task = Tasks::Simple.new)
                exec = Roby::Tasks::Simple.new
                assert_raises(ArgumentError) do
                    task.executed_by exec
                end
                exec = Roby::Tasks::Simple.new_submodel do
                    event :ready
                end.new
                task.executed_by exec
            end

            def test_agent_fails
                plan.add(task = Tasks::Simple.new)
                task.executed_by(exec = ExecutionAgentModel.new)
                task.execution_agent
                execute do
                    exec.start!
                    exec.ready_event.emit
                    task.start!
                end

                expect_execution { exec.stop! }
                    .to { emit task.aborted_event }
            end

            def test_task_has_wrong_agent
                task_model = Tasks::Simple.new_submodel
                task_model.executed_by ExecutionAgentModel, id: 2

                # Wrong agent type
                plan.add(task = task_model.new)
                assert_raises(Roby::ModelViolation) do
                    task.executed_by SecondExecutionModel.new(id: 2)
                end
                assert !task.execution_agent

                # Wrong agent arguments
                plan.add(task = task_model.new)
                assert_raises(Roby::ModelViolation) do
                    task.executed_by SecondExecutionModel.new(id: 2)
                end
                assert !task.execution_agent
            end

            def test_model_requires_agent_but_none_exists
                task_model = Tasks::Simple.new_submodel
                task_model.executed_by ExecutionAgentModel, id: 2
                plan.add(task = task_model.new)
                expect_execution { task.start! }
                    .to { fail_to_start task, reason: TaskStructure::MissingRequiredExecutionAgent }
            end

            def test_as_plan
                model = Tasks::Simple.new_submodel do
                    event :ready, controlable: true
                end
                flexmock(model).should_receive(:as_plan).and_return { model.new(id: 10) }
                root = prepare_plan add: 1, model: Tasks::Simple
                agent = root.executed_by(model)
                assert_kind_of model, agent
                assert_equal 10, agent.arguments[:id]
            end

            def test_it_refuses_setting_up_an_agent_on_a_running_task
                plan.add(task = Tasks::Simple.new)
                plan.add(agent = ExecutionAgentModel.new)
                execute { task.start! }
                assert_raises(TaskStructure::ExecutedTaskAlreadyRunning) do
                    task.executed_by agent
                end
            end

            def test_starting_a_task_raises_if_started_while_the_agent_is_not_ready
                plan.add(task = Tasks::Simple.new)
                plan.add(agent = ExecutionAgentModel.new)
                task.executed_by agent
                expect_execution { task.start! }
                    .to { fail_to_start task, reason: TaskStructure::ExecutionAgentNotReady }
            end

            it "marks the executed tasks as failed_to_start if the agent's ready_event becomes unreachable" do
                plan.add(task = Tasks::Simple.new)
                task.executed_by(agent = BaseExecutionAgent.new)
                execute { agent.start! }

                error_m = Class.new(LocalizedError)
                expect_execution { agent.ready_event.unreachable!(error_m.new(task)) }
                    .to { fail_to_start task, reason: error_m }
            end

            it "does not mark the executed task as failed_to_start because the ready_event becomes unreachable once it has been emitted" do
                plan.add(task = Tasks::Simple.new)
                task.executed_by(agent = BaseExecutionAgent.new)
                execute do
                    agent.start!
                    agent.ready_event.emit
                end
                execute do
                    agent.ready_event.unreachable!
                end
                refute task.failed_to_start?
                execute { task.start! }
            end
            it "does not mark the executed task as failed_to_start when the ready_event becomes unreachable if the relation was established after the event's emission" do
                plan.add(task = Tasks::Simple.new)
                plan.add(agent = BaseExecutionAgent.new)
                execute do
                    agent.start!
                    agent.ready_event.emit
                end
                task.executed_by(agent)
                execute do
                    agent.ready_event.unreachable!
                end
                refute task.failed_to_start?
                execute { task.start! }
            end
        end
    end
end
