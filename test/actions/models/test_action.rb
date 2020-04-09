# frozen_string_literal: true

require "roby/test/self"

describe Roby::Actions::Models::Action do
    describe "#plan_pattern" do
        attr_reader :action_m
        before do
            task_m = Roby::Task.new_submodel
            interface_m = Roby::Actions::Interface.new_submodel do
                describe("action").required_arg("arg").returns(task_m)
                def test(args = {}); end
            end
            @action_m = interface_m.find_action_by_name("test")
        end

        it "sets the job ID if given" do
            plan.add(task = action_m.plan_pattern(job_id: 10))
            assert_equal 10, task.planning_task.job_id
        end
        it "passes the arguments to the planning task" do
            plan.add(task = action_m.plan_pattern(job_id: 10, arg: 20))
            assert_equal Hash[arg: 20], task.planning_task.action_arguments
        end
        it "does not set the job ID at all if not given" do
            plan.add(task = action_m.plan_pattern)
            # Will raise if the job ID has been assigned, even if it is nil
            task.planning_task.job_id = 10
        end
    end

    describe "#returned_task_type" do
        before do
            interface_m = Roby::Actions::Interface.new_submodel
            @action_m   = Roby::Actions::Models::Action.new(interface_m)
        end
        it "returns the specified returned type if it is a task model" do
            @action_m.returns(task_m = Roby::Task.new_submodel)
            assert_same task_m, @action_m.returned_task_type
        end
        it "returns a new anonymous model if it is a service model" do
            srv_m = Roby::TaskService.new_submodel
            @action_m.returns(srv_m)
            task_m = @action_m.returned_task_type
            assert(task_m <= srv_m)
        end
        it "returns always the same anonymous model" do
            srv_m = Roby::TaskService.new_submodel
            @action_m.returns(srv_m)
            task_m = @action_m.returned_task_type
            assert_same task_m, @action_m.returned_task_type
        end
    end

    describe "#update" do
        attr_reader :action_m, :updated_m
        before do
            interface_m = Roby::Actions::Interface.new_submodel
            @action_m   = Roby::Actions::Models::Action.new(interface_m)
            @updated_m  = Roby::Actions::Models::Action.new(interface_m)
        end

        it "replaces existing argument description by new ones" do
            action_m.required_arg("test", "test documentation")
            updated_m.optional_arg("test", "updated documentation", 10)
            updated_m.overloads(action_m)

            arg = updated_m.find_arg("test")
            refute_same arg, action_m.find_arg("test")
            assert !arg.required?
            assert_equal "updated documentation", arg.doc
            assert_equal 10, arg.default
        end
        it "keeps existing argument description that are not overriden" do
            action_m.required_arg("test", "test documentation")
            updated_m.optional_arg("test2", "updated documentation", 10)
            updated_m.overloads(action_m)
            assert updated_m.has_arg?("test")
            assert updated_m.has_arg?("test2")
        end
        it "updates the return type if a submodel task model is provided" do
            task_m = Roby::Task.new_submodel
            action_m.returns(task_m)
            subtask_m = task_m.new_submodel
            updated_m.returns(subtask_m)
            updated_m.overloads(action_m)
            assert_same subtask_m, updated_m.returned_type
        end
        it "updates the return type if a submodel service model is provided" do
            srv_m = Roby::TaskService.new_submodel
            action_m.returns(srv_m)
            subsrv_m = srv_m.new_submodel
            updated_m.returns(subsrv_m)
            updated_m.overloads(action_m)
            assert_same subsrv_m, updated_m.returned_type
        end
        it "does not update the argument if validation fails" do
            action_m.required_arg("test", "")
            original_args = updated_m.arguments.dup
            flexmock(updated_m).should_receive(:validate_can_overload).and_raise(ArgumentError)
            assert_raises(ArgumentError) { updated_m.overloads(action_m) }
            assert_equal original_args, updated_m.arguments
        end
        it "updates the return type if the new action's return type is a service and self does not have a return type defined" do
            srv_m = Roby::TaskService.new_submodel
            updated_m.returns(srv_m)
            updated_m.overloads(action_m)
            assert_same srv_m, updated_m.returned_type
        end
    end
    describe "#validate_can_overload" do
        attr_reader :action_m, :updated_m
        before do
            interface_m = Roby::Actions::Interface.new_submodel
            @action_m   = Roby::Actions::Models::Action.new(interface_m)
            @updated_m  = Roby::Actions::Models::Action.new(interface_m)
        end

        it "raises ArgumentError if the provided return model is not a submodel task model of the current one" do
            task_m = Roby::Task.new_submodel
            action_m.returns(task_m)
            other_m = Roby::Task.new_submodel
            updated_m.returns(other_m)
            assert_raises(ArgumentError) do
                updated_m.validate_can_overload(action_m)
            end
        end
        it "raises ArgumentError if the provided return model is not a submodel service model of the current one" do
            srv_m = Roby::TaskService.new_submodel
            action_m.returns(srv_m)
            other_m = Roby::TaskService.new_submodel
            updated_m.returns(other_m)
            assert_raises(ArgumentError) do
                updated_m.validate_can_overload(action_m)
            end
        end
    end

    describe "#has_arg?" do
        attr_reader :action_m
        before do
            interface_m = Roby::Actions::Interface.new_submodel
            @action_m   = Roby::Actions::Models::Action.new(interface_m)
        end
        it "matches string and symbol names" do
            action_m.optional_arg("string_name")
            action_m.optional_arg("symbol_name")
            assert action_m.has_arg?("string_name")
            assert action_m.has_arg?(:string_name)
            assert action_m.has_arg?("symbol_name")
            assert action_m.has_arg?(:symbol_name)
        end
        it "returns false on a non-existent argument" do
            refute action_m.has_arg?("does_not_exist")
            refute action_m.has_arg?(:does_not_exist)
        end
    end

    describe "#pretty_print" do
        before do
            interface_m = Roby::Actions::Interface.new_submodel
            @action_m   = Roby::Actions::Models::Action.new(interface_m)
        end

        it "pretty prints an action model" do
            expected = <<~TEXT
                Action #{@action_m}
                  Returns Roby::Task
                  No arguments.
            TEXT
            assert_equal expected, PP.pp(@action_m, "".dup)
        end

        it "displays No arguments if there are no arguments" do
        end

        it "pretty-prints the argument definitions" do
            @action_m.optional_arg("opt_arg_no_default", "opt arg no default doc")
            @action_m.optional_arg("opt_arg", "opt arg doc", 10)
            @action_m.required_arg("req_arg", "req arg doc")
            expected = <<~TEXT
                Action #{@action_m}
                  Returns Roby::Task
                  Arguments:
                    opt_arg: opt arg doc (optional) default=10
                    opt_arg_no_default: opt arg no default doc (optional)
                    req_arg: req arg doc (required)
            TEXT
            assert_equal expected, PP.pp(@action_m, "".dup)
        end
    end
end
