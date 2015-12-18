require 'roby/test/self'

describe Roby::TaskArguments do
    attr_reader :task_m, :task
    before do
        @task_m = Roby::Task.new_submodel { argument :arg }
        @task = task_m.new
        plan.add(task)
    end

    describe "#[]=" do
        it "should allow assignation to unset arguments" do
            plan.add(task = task_m.new)
            task.arguments[:arg] = 'A'
            assert_equal('A', task.arg)
            assert_equal({ arg: 'A' }, task.arguments)
        end

        it "should not allow overriding already set arguments" do
            plan.add(task = task_m.new(arg: 'B'))
            assert_raises(ArgumentError) { task.arg = 10 }
        end

        it "should allow overriding already set arguments that are not meaningful" do
            plan.add(task = task_m.new(arg: 'B', useless: 'bla'))
            task.arguments[:bar] = 42
            task.arguments[:bar] = 43
        end

        it "should allow overriding delayed arguments" do
            arg = flexmock(evaluate_delayed_argument: nil)
            plan.add(task = task_m.new)
            task.arguments[:arg] = arg
            task.arguments[:arg] = 10
        end
    end

    describe "#set?" do
        it "should return true if the argument is set" do
            plan.add(task = task_m.new(arg: 10))
            assert task.arguments.set?(:arg)
        end
        it "should return true if the argument is set, even to nil" do
            plan.add(task = task_m.new(arg: nil))
            assert task.arguments.set?(:arg)
        end
        it "should return false if the argument is a delayed argument" do
            plan.add(task = task_m.new(arg: flexmock(evaluate_delayed_argument: nil)))
            assert !task.arguments.set?(:arg)
        end
    end

    describe "#static?" do
        it "should return true if all values are plain" do
            plan.add(task = task_m.new(arg0: 10, arg1: 20))
            assert task.arguments.static?
        end
        it "should return false if some values are delayed" do
            delayed_arg = flexmock(evaluate_delayed_argument: nil)
            plan.add(task = task_m.new(arg0: 10, arg1: delayed_arg))
            assert !task.arguments.static?
        end
        it "be updated if []= is called to replace a delayed argument by a plain value" do
            delayed_arg = flexmock(evaluate_delayed_argument: nil)
            plan.add(task = task_m.new(arg0: 10, arg1: delayed_arg))
            task.arguments[:arg1] = 20
            assert task.arguments.static?
        end
    end

    describe "#merge!" do
        it "resets the static flag if new delayed values are added" do
            args = Roby::TaskArguments.new(task_m.new)
            args.merge!(key: flexmock(evaluate_delayed_argument: 10))
            assert !args.static?
        end
        it "does not raise if the hash updates a non-writable value with the same value" do
            args = task_m.new(arg: 20).arguments
            args.merge!(arg: 20)
            assert_equal 20, args[:arg]
        end
        it "does not raise if the hash updates a writable value" do
            args = task_m.new(arg: flexmock(evaluate_delayed_argument: 10)).arguments
            args.merge!(arg: 20)
            assert_equal 20, args[:arg]
        end
        it "raises if an updated value is not writable" do
            args = task_m.new(arg: 20).arguments
            assert_raises(ArgumentError) do
                args.merge!(arg: flexmock(evaluate_delayed_argument: 10))
            end
        end
    end

    describe "#force_merge!" do
        let(:task) do
            task_m.new arg:  10
        end

        it "forcefully sets the arguments to the values in the hash" do
            task.arguments.force_merge!(arg: 20)
            assert_equal 20, task.arg
        end
        it "updates the static flag" do
            task.arguments.force_merge!(arg: flexmock(evaluate_delayed_argument: 10))
            assert !task.arguments.static?
        end
    end

    describe "#evaluate_delayed_arguments" do
        it "returns a hash of the arguments value" do
            task = task_m.new arg:  10
            assert_equal Hash[arg: 10], task.arguments.evaluate_delayed_arguments
        end
        it "does not set the delayed arguments that have no value" do
            delayed_arg = flexmock do |r|
                r.should_receive(:evaluate_delayed_argument).and_throw(:no_value)
            end
            task = task_m.new arg: delayed_arg
            assert_equal Hash[], task.arguments.evaluate_delayed_arguments
        end
        it "sets evaluated delayed arguments" do
            delayed_arg = flexmock do |r|
                r.should_receive(:evaluate_delayed_argument).and_return(20)
            end
            task = task_m.new arg: delayed_arg
            assert_equal Hash[arg: 20], task.arguments.evaluate_delayed_arguments
        end
    end

    describe "#each" do
        it "enumerates all arguments including the delayed ones" do
            delayed_arg = flexmock(evaluate_delayed_argument: 20)
            args = task_m.new(arg: 10, key: delayed_arg).arguments
            assert_equal [[:arg, 10], [:key, delayed_arg]], args.each.to_a
        end
    end

    describe "#each_assigned_argument" do
        it "enumerates all arguments except the delayed ones" do
            args = task_m.new(arg: 10, key: flexmock(evaluate_delayed_argument: 20)).arguments
            assert_equal [[:arg, 10]], args.each_assigned_argument.to_a
        end
    end
end

describe Roby::DelayedArgumentFromObject do
    it "can be droby-marshalled" do
	obj = Object.new
	arg = Roby::DelayedArgumentFromObject.new(obj, false).bla

        dump = arg.droby_dump(nil)
        dump = Marshal.dump(dump)
        loaded = Marshal.load(dump).proxy(Roby::Distributed::DumbManager)
        assert_kind_of Object, arg.instance_variable_get(:@object)
	assert_equal [:bla], arg.instance_variable_get(:@methods)
	assert_equal Object, arg.instance_variable_get(:@expected_class)
	assert !arg.instance_variable_get(:@weak)
    end

    describe "#evaluate_delayed_argument" do
        attr_reader :task, :arg
        before do
            task_m = Roby::Task.new_submodel { argument(:arg) }
            @task = prepare_plan add: 1, model: task_m
            @arg = Roby::DelayedArgumentFromObject.new(task).arg.field
        end

        it "resolves to a task's arguments" do
            task.arg = Struct.new(:field).new(10)
            assert_equal 10, arg.evaluate_delayed_argument(task)
        end
        it "throws no_value if trying to access an unassigned argument" do
            assert_throws(:no_value) do
                arg.evaluate_delayed_argument(task)
            end
        end
        it "recursively resolves task arguments" do
            task.arg = Class.new do
                def evaluate_delayed_argument(task); Struct.new(:field).new(10) end
            end.new
            assert_equal 10, arg.evaluate_delayed_argument(task)
        end
        it "throws no_value if trying to access a delayed task argument that cannot be resolved" do
            task.arg = Class.new do
                def evaluate_delayed_argument(task); throw :no_value end
            end.new
            assert_throws(:no_value) do
                arg.evaluate_delayed_argument(task)
            end
        end
    end
end

describe Roby::DelayedArgumentFromState do
    it "can be droby-marshalled" do
	arg = Roby::DelayedArgumentFromState.new.bla

        dump = arg.droby_dump(nil)
        dump = Marshal.dump(dump)
        loaded = Marshal.load(dump).proxy(Roby::Distributed::DumbManager)
        assert_kind_of Roby::StateSpace, arg.instance_variable_get(:@object)
	assert_equal [:bla], arg.instance_variable_get(:@methods)
	assert_equal Object, arg.instance_variable_get(:@expected_class)
	assert arg.instance_variable_get(:@weak)
    end
end

