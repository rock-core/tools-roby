$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Coordination::ActionScript do
    include Roby::SelfTest

    attr_reader :task_model, :root_task, :script_task, :script_model
    before do
        @script_model = Roby::Coordination::ActionScript.new_submodel(:action_interface => flexmock(:find_action_by_name => nil))
        @task_model = Class.new(Roby::Tasks::Simple) do
            event :intermediate
        end
        @script_task =
            flexmock(Roby::Coordination::Models::TaskWithDependencies.new(task_model))
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
                assert_raises(Roby::Coordination::Script::DeadInstruction) { action_task.intermediate_event.unreachable! }
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
                assert_raises(Roby::Coordination::Script::DeadInstruction) do
                    action_task.intermediate_event.emit
                end
            end
        end

        it "is robust to replacement in the error case" do
            action_model = Roby::Actions::Interface.new_submodel do
                describe ''
                action_script 'test' do
                    t = task Roby::Tasks::Simple
                    execute t, :role => 'test'
                    emit success_event
                end
            end
            root_task = action_model.test.instanciate(plan)
            root_task.start!
            plan.force_replace(
                child = root_task.test_child,
                new_child = Roby::Tasks::Simple.new)
            child.start!
            child.success_event.emit
            inhibit_fatal_messages do
                assert_raises(Roby::Coordination::Models::Script::DeadInstruction) do
                    new_child.failed_to_start!(nil)
                end
            end
        end

        it "is robust to replacement on the nominal case" do
            action_model = Roby::Actions::Interface.new_submodel do
                describe ''
                action_script 'test' do
                    t = task Roby::Tasks::Simple
                    execute t, :role => 'test'
                    emit success_event
                end
            end
            root_task = action_model.test.instanciate(plan)
            root_task.start!
            plan.force_replace(root_task.test_child, new_child = Roby::Tasks::Simple.new)
            new_child.start!
            new_child.success_event.emit
            assert root_task.success?
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

