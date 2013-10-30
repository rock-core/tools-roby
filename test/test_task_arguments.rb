$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'

describe Roby::TaskArguments do
    include Roby::SelfTest

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
            assert_equal({ :arg => 'A' }, task.arguments)
        end

        it "should not allow overriding already set arguments" do
            plan.add(task = task_m.new(:arg => 'B'))
            assert_raises(ArgumentError) { task.arg = 10 }
        end

        it "should allow overriding already set arguments that are not meaningful" do
            plan.add(task = task_m.new(:arg => 'B', :useless => 'bla'))
            task.arguments[:bar] = 42
            task.arguments[:bar] = 43
        end

        it "should allow overriding delayed arguments" do
            arg = flexmock(:evaluate_delayed_argument => nil)
            plan.add(task = task_m.new)
            task.arguments[:arg] = arg
            task.arguments[:arg] = 10
        end
    end

    describe "#set?" do
        it "should return true if the argument is set" do
            plan.add(task = task_m.new(:arg => 10))
            assert task.arguments.set?(:arg)
        end
        it "should return true if the argument is set, even to nil" do
            plan.add(task = task_m.new(:arg => nil))
            assert task.arguments.set?(:arg)
        end
        it "should return false if the argument is a delayed argument" do
            plan.add(task = task_m.new(:arg => flexmock(:evaluate_delayed_argument => nil)))
            assert !task.arguments.set?(:arg)
        end
    end

    describe "#static?" do
        it "should return true if all values are plain" do
            plan.add(task = task_m.new(:arg0 => 10, :arg1 => 20))
            assert task.arguments.static?
        end
        it "should return false if some values are delayed" do
            delayed_arg = flexmock(:evaluate_delayed_argument => nil)
            plan.add(task = task_m.new(:arg0 => 10, :arg1 => delayed_arg))
            assert !task.arguments.static?
        end
        it "be updated if []= is called to replace a delayed argument by a plain value" do
            delayed_arg = flexmock(:evaluate_delayed_argument => nil)
            plan.add(task = task_m.new(:arg0 => 10, :arg1 => delayed_arg))
            task.arguments[:arg1] = 20
            assert task.arguments.static?
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

