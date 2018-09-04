require 'roby/test/self'
require 'roby/tasks/simple'

module Roby
    module Coordination
describe ActionScript do
    attr_reader :task_model, :root_task, :script_task, :script_model
    before do
        @task_model = Class.new(Tasks::Simple) do
            event :intermediate
        end
        @script_model = ActionScript.new_submodel(action_interface: flexmock(find_action_by_name: nil), root: task_model)
        @script_task =
            flexmock(Models::TaskWithDependencies.new(task_model))
        script_model.tasks << script_task
        plan.add(@root_task = task_model.new)
    end

    describe "#wait" do
        attr_reader :action_task
        before do
            script_model.start script_task
            script_model.wait script_task.intermediate_event
            script_task.should_receive(:instanciate).
                and_return { @action_task = task_model.new }.by_default
        end

        def start_script
            script = script_model.new(root_task)
            execute { root_task.start! }
            execute { action_task.start! }
            script
        end

        it "waits for a new emission on an event" do
            script = start_script
            assert !script.finished?
            expect_execution { action_task.intermediate_event.emit }.
                to { achieve { script.finished? } }
        end

        it "does wait even if the event was already emitted" do
            script_model.wait script_task.intermediate_event
            script = start_script

            execute { action_task.intermediate_event.emit }
            refute script.finished?
            execute { action_task.intermediate_event.emit }
            assert script.finished?
        end

        it "fails if asked to wait for an unreachable event" do
            start_script
            expect_execution { action_task.intermediate_event.unreachable! }.
                to { have_error_matching Models::Script::DeadInstruction.match.with_origin(root_task) }
        end

        it "fails if the event it is waiting for becomes unreachable" do
            task_model.event :second
            script_model.wait script_task.second_event
            start_script
            execute { action_task.second_event.unreachable! }
            expect_execution { action_task.intermediate_event.unreachable! }.
                to { have_error_matching Models::Script::DeadInstruction.match.with_origin(root_task) }
        end

        it "can wait for one of its own events" do
            script_model = ActionScript.new_submodel(action_interface: flexmock(find_action_by_name: nil), root: task_model)
            script_model.wait script_model.intermediate_event
            script = script_model.new(root_task)
            expect_execution do
                root_task.start!
                root_task.intermediate_event.emit
            end.to { achieve { script.finished? } }
        end

        it "is robust to replacement in the error case" do
            action_m = Roby::Actions::Interface.new_submodel do
                describe ''
                action_script 'test' do
                    t = task Tasks::Simple
                    execute t, role: 'test'
                    emit success_event
                end
            end
            root_task = action_m.test.instanciate(plan)
            execute { root_task.start! }
            plan.force_replace(
                child = root_task.test_child,
                new_child = Tasks::Simple.new)
            execute do
                child.start!
                child.success_event.emit
            end
            expect_execution { new_child.failed_to_start!(nil) }.
                to { have_error_matching ChildFailedError.match.with_origin(new_child.start_event) }
        end

        it "is robust to replacement on the nominal case" do
            action_m = Roby::Actions::Interface.new_submodel do
                describe ''
                action_script 'test' do
                    t = task Tasks::Simple
                    execute t, role: 'test'
                    emit success_event
                end
            end
            root_task = action_m.test.instanciate(plan)
            execute { root_task.start! }
            plan.force_replace(root_task.test_child, new_child = Tasks::Simple.new(id: root_task.test_child.id))
            expect_execution do
                new_child.start!
                new_child.success_event.emit
            end.to { emit root_task.success_event }
        end
    end

    describe "#start" do
        it "can start an action" do
            script_task.should_receive(:instanciate).
                and_return(action_task = task_model.new)
            script_model.start script_task
            script = script_model.new(root_task)
            execute { root_task.start! }
            assert_equal action_task, root_task.current_task_child
            refute script.finished?
            execute { action_task.start! }
            assert script.finished?
        end
    end

    describe "#forward" do
        it "can forward an event to the root task" do
            script_task.should_receive(:instanciate).
                and_return(action_task = task_model.new)
            script_model.forward script_task.intermediate_event, script_model.success_event
            script_model.start script_task
            script_model.new(root_task)
            execute { root_task.start! }
            expect_execution do
                action_task.start!
                action_task.intermediate_event.emit
            end.to do
                emit root_task.success_event
            end
        end
    end
end
    end
end
