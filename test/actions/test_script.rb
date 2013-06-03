$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Actions::Script do
    include Roby::SelfTest

    attr_reader :task_model, :root_task, :script_task, :script_model
    before do
        @script_model = Roby::Actions::Script.new_submodel(flexmock(:find_action_by_name => nil))
        @task_model = Class.new(Roby::Tasks::Simple) do
            event :intermediate
        end
        @script_task =
            flexmock(Roby::Actions::Models::ActionCoordination::TaskWithDependencies.new(task_model))
        script_model.tasks << script_task
        plan.add(@root_task = Roby::Tasks::Simple.new)
    end

    describe "#wait" do
        attr_reader :action_task
        before do
            script_task.should_receive(:instanciate).
                and_return(@action_task = task_model.new).by_default
            script_model.start script_task
            script_model.wait script_task.intermediate_event
        end

        it "waits for a new emission on an event" do
            script = script_model.new(script_model.action_interface, root_task)
            root_task.start!
            action_task.start!
            assert !script.finished?
            action_task.intermediate_event.emit
            assert script.finished?
        end

        it "does wait even if the event was already emitted" do
            script_model.wait script_task.intermediate_event
            script = script_model.new(script_model.action_interface, root_task)
            root_task.start!
            action_task.start!
            assert !script.finished?
            action_task.intermediate_event.emit
            assert !script.finished?
            action_task.intermediate_event.emit
            assert script.finished?
        end

        it "fails if asked to wait for an unreachable event" do
            script = script_model.new(script_model.action_interface, root_task)
            root_task.start!
            action_task.start!
            inhibit_fatal_messages do
                assert_raises(Roby::Actions::Script::DeadInstruction) { action_task.intermediate_event.unreachable! }
            end
        end

        it "fails if the event it is waiting for becomes unreachable" do
            task_model.event :second
            script_model.wait script_task.second_event
            script_task.should_receive(:instanciate).
                and_return(action_task = task_model.new)

            script = script_model.new(script_model.action_interface, root_task)
            root_task.start!
            action_task.start!
            action_task.second_event.unreachable!
            inhibit_fatal_messages do
                assert_raises(Roby::Actions::Script::DeadInstruction) do
                    action_task.intermediate_event.emit
                end
            end
        end
    end

    describe "#start" do
        it "can start an action" do
            script_task.should_receive(:instanciate).
                and_return(action_task = task_model.new)
            script_model.start script_task
            script = script_model.new(script_model.action_interface, root_task)
            root_task.start!
            assert_equal action_task, root_task.current_task_child
            assert !script.finished?
            action_task.start!
            assert script.finished?
        end
    end

    describe "#forward" do
        it "can forward an event to the root task" do
            script_task.should_receive(:instanciate).
                and_return(action_task = task_model.new)
            script_model.forward script_task.intermediate_event, script_model.success_event
            script_model.start script_task
            script = script_model.new(script_model.action_interface, root_task)
            root_task.start!
            action_task.start!
            action_task.intermediate_event.emit
            assert root_task.success?
        end
    end
end

