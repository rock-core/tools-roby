require 'roby/test/self'

describe Roby::Actions::Models::Action do
    it "can be dumped and then reloaded" do
        task_m = Roby::Task.new_submodel
        interface_m = Roby::Actions::Interface.new_submodel do
            describe('action').
                returns(task_m)
            def an_action; end
        end

        action_m = interface_m.find_action_by_name('an_action')
        dump = action_m.droby_dump(nil)
        Marshal.dump(dump)
        loaded = dump.proxy(nil)
        assert_same action_m, loaded
    end

    it "can marshal actions with non trivial default arguments" do
        task_m = Roby::Task.new_submodel
        interface_m = Roby::Actions::Interface.new_submodel do
            describe('action').
                optional_arg('test', '', task_m).
                returns(task_m)
            def an_action(arguments = Hash.new); end
        end

        action_m = interface_m.find_action_by_name('an_action')
        dump = action_m.droby_dump(nil)
        dump = Marshal.load(Marshal.dump(dump))
        loaded = dump.proxy(nil)
        assert_same action_m, loaded
    end

    describe "#plan_pattern" do
        attr_reader :action_m
        before do
            task_m = Roby::Task.new_submodel
            interface_m = Roby::Actions::Interface.new_submodel do
                describe('action').required_arg('arg').returns(task_m)
                def test(args = Hash.new); end
            end
            @action_m = interface_m.find_action_by_name('test')
        end

        it "sets the job ID if given" do
            plan.add(task = action_m.plan_pattern(:job_id => 10))
            assert_equal 10, task.planning_task.job_id
        end
        it "passes the arguments to the planning task" do
            plan.add(task = action_m.plan_pattern(:job_id => 10, :arg => 20))
            assert_equal Hash[:arg => 20], task.planning_task.action_arguments
        end
        it "does not set the job ID at all if not given" do
            plan.add(task = action_m.plan_pattern)
            # Will raise if the job ID has been assigned, even if it is nil
            task.planning_task.job_id = 10
        end
    end
end

