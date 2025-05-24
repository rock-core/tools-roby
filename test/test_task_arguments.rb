# frozen_string_literal: true

require "roby/test/self"

describe Roby::TaskArguments do
    attr_reader :task_m, :task

    before do
        @task_m = Roby::Task.new_submodel { argument :arg }
        @task = task_m.new
        plan.add(task)
    end

    describe "#[]=" do
        it "sets the argument if writable? returns true" do
            flexmock(task.arguments).should_receive(:writable?)
                .with(:arg, "A").once.and_return(true)
            task.arguments[:arg] = "A"
            assert_equal("A", task.arg)
            assert_equal({ arg: "A" }, task.arguments)
        end

        it "raises if writable? returns false" do
            flexmock(task.arguments).should_receive(:writable?)
                .with(:arg, "A").once.and_return(false)
            assert_raises(ArgumentError) do
                task.arguments[:arg] = "A"
            end
        end

        it "raises NotMarshallable if attempting to set an argument that is marked with the DRoby::Unmarshallable module" do
            object = Object.new
            object.extend Roby::DRoby::Unmarshallable
            e = assert_raises Roby::NotMarshallable do
                task.arguments[:arg] = object
            end
            assert_equal "values used as task arguments must be marshallable, attempting to set arg to #{object} of class Object, which is not", e.message
        end
    end

    describe "#writable?" do
        it "returns true for unset arguments" do
            task = task_m.new
            assert task.arguments.writable?(:arg, "A")
        end

        it "returns false for arguments set with non-delayed argument objects" do
            plan.add(task = task_m.new(arg: "B"))
            refute task.arguments.writable?(:arg, 10)
        end

        it "returns true for arguments that are set but not meaningful" do
            plan.add(task = task_m.new(arg: "B", useless: "bla"))
            task.arguments[:bar] = 42
            task.arguments.writable?(:bar, 43)
        end

        it "returns true if the current argument is a delayed arg object and the new argument is not" do
            arg = flexmock(evaluate_delayed_argument: nil)
            task = task_m.new(arg: arg)
            assert task.arguments.writable?(:arg, 10)
        end

        it "returns true if the current and new arguments are both delayed arg objects" do
            arg = flexmock(evaluate_delayed_argument: nil)
            new_arg = flexmock(evaluate_delayed_argument: nil)
            task = task_m.new(arg: arg)
            assert task.arguments.writable?(:arg, new_arg)
        end
    end

    # This is a custom implementation in TaskArguments, we must test it here
    # rubocop:disable Style/PreferredHashMethods
    describe "#has_key?" do
        before do
            flexmock(Roby).should_receive(:warn_deprecated)
        end

        it "returns true if the argument is set" do
            plan.add(task = task_m.new(arg: 10))
            assert task.arguments.has_key?(:arg)
        end
        it "returns true if the argument is set, even to nil" do
            plan.add(task = task_m.new(arg: nil))
            assert task.arguments.has_key?(:arg)
        end
        it "returns true if the argument is a delayed argument" do
            plan.add(task = task_m.new(arg: flexmock(evaluate_delayed_argument: nil)))
            assert task.arguments.has_key?(:arg)
        end
        it "returns false if the argument is not set" do
            refute task.arguments.has_key?(:arg)
        end
    end
    # rubocop:enable Style/PreferredHashMethods

    describe "#key?" do
        it "returns true if the argument is set" do
            plan.add(task = task_m.new(arg: 10))
            assert task.arguments.key?(:arg)
        end
        it "returns true if the argument is set, even to nil" do
            plan.add(task = task_m.new(arg: nil))
            assert task.arguments.key?(:arg)
        end
        it "returns true if the argument is a delayed argument" do
            plan.add(task = task_m.new(arg: flexmock(evaluate_delayed_argument: nil)))
            assert task.arguments.key?(:arg)
        end
        it "returns false if the argument is not set" do
            refute task.arguments.key?(:arg)
        end
    end

    describe "#set?" do
        it "returns false if the argument is not set" do
            refute task.arguments.set?(:arg)
        end
        it "returns true if the argument is set" do
            plan.add(task = task_m.new(arg: 10))
            assert task.arguments.set?(:arg)
        end
        it "returns true if the argument is set, even to nil" do
            plan.add(task = task_m.new(arg: nil))
            assert task.arguments.set?(:arg)
        end
        it "returns false if the argument is a delayed argument" do
            plan.add(task = task_m.new(arg: flexmock(evaluate_delayed_argument: nil)))
            refute task.arguments.set?(:arg)
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
        it "raises if attempting to set to a non-marshallable value" do
            args = Roby::TaskArguments.new(task_m.new)
            object = Object.new
            object.extend Roby::DRoby::Unmarshallable
            e = assert_raises Roby::NotMarshallable do
                args.merge!(key: object)
            end
            assert_equal "values used as task arguments must be marshallable, attempting to set key to #{object}, which is not", e.message
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
            task_m.new arg: 10
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
            task = task_m.new arg: 10
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

    describe "#each_delayed_argument" do
        it "enumerates all delayed arguments" do
            delayed_arg = flexmock(evaluate_delayed_argument: 20)
            args = task_m.new(arg: 10, key: delayed_arg).arguments
            assert_equal [[:key, delayed_arg]], args.each_delayed_argument.to_a
        end
    end

    describe "#can_semantic_merge? and #semantic_merge!" do
        before do
            @left_t = Roby::Task.new_submodel.new
            @left = Roby::TaskArguments.new(@left_t)
            @right_t = Roby::Task.new_submodel.new
            @right = Roby::TaskArguments.new(@right_t)
        end

        it "sets static?=true if the merges removes all delayed arguments" do
            @left[:arg] = flexmock(evaluate_delayed_argument: nil, strong?: false)
            @right[:arg] = 42
            @left.semantic_merge!(@right)
            assert @left.static?
        end

        it "keeps static?=false if the merges does not remove all delayed arguments" do
            @left[:arg] = flexmock(evaluate_delayed_argument: nil, strong?: true)
            @right[:arg] = flexmock(evaluate_delayed_argument: nil, strong?: false)
            @left.semantic_merge!(@right)
            refute @left.static?
        end

        it "logs a :task_arguments_updated event if the value has been changed" do
            @left[:arg] = flexmock(
                evaluate_delayed_argument: nil, strong?: true, merge: 42)
            @right[:arg] = 42
            flexmock(@left.task.plan).should_receive(:log)
                .once.with(:task_arguments_updated, @left.task, :arg, 42)
            @left.semantic_merge!(@right)
        end

        it "does not log a :task_arguments_updated event if the value has not been changed" do
            @left[:arg] = flexmock(evaluate_delayed_argument: nil, strong?: true)
            @right[:arg] = flexmock(evaluate_delayed_argument: nil, strong?: false)
            flexmock(@left.task.plan).should_receive(:log).never
            @left.semantic_merge!(@right)
        end

        it "logs a :task_arguments_updated event for new arguments" do
            @right[:something] = 42
            flexmock(@left.task.plan).should_receive(:log).once
                .with(:task_arguments_updated, @left.task, :something, 42)
            @left.semantic_merge!(@right)
        end

        describe "non-delayed arguments" do
            it "can merge if they are equal, and returns the value" do
                @left[:arg] = 10
                @right[:arg] = 10
                assert @left.can_semantic_merge?(@right)
                @left.semantic_merge!(@right)
                assert_equal 10, @left[:arg]
            end

            it "can not merge if they are not equal" do
                @left[:arg] = 10
                @right[:arg] = 20
                refute @left.can_semantic_merge?(@right)
            end
        end

        describe "one non-delayed argument and one strong delayed argument" do
            before do
                @left[:arg] = flexmock(evaluate_delayed_argument: true, strong?: true)
                @right[:arg] = 42
            end

            it "can merge if can_merge? returns true" do
                @left.values[:arg].should_receive(:can_merge?)
                    .with(@left_t, @right_t,
                          ->(a) { a.evaluate_delayed_argument(nil) == 42 })
                    .twice.and_return(true)
                assert @left.can_semantic_merge?(@right)
                assert @right.can_semantic_merge?(@left)
            end

            it "uses the value returned by merge" do
                @left.values[:arg].should_receive(:merge)
                    .with(@left_t, @right_t,
                          ->(a) { a.evaluate_delayed_argument(nil) == 42 })
                    .once.and_return(10)
                @left.semantic_merge!(@right)
                assert_equal 10, @left[:arg]
            end

            it "behaves identically if the delayed argument is passed as argument" do
                @left.values[:arg].should_receive(:merge)
                    .with(@left_t, @right_t,
                          ->(a) { a.evaluate_delayed_argument(nil) == 42 })
                    .once.and_return(10)
                @right.semantic_merge!(@left)
                assert_equal 10, @right.values[:arg]
            end

            it "returns false if can_merge? returns false" do
                @left.values[:arg].should_receive(:can_merge?)
                    .with(@left_t, @right_t,
                          ->(a) { a.evaluate_delayed_argument(nil) == 42 })
                    .twice.and_return(false)
                refute @left.can_semantic_merge?(@right)
                refute @right.can_semantic_merge?(@left)
            end
        end

        describe "one non-delayed argument and one weak delayed argument" do
            before do
                @left[:arg] = flexmock(evaluate_delayed_argument: true, strong?: false)
                @right[:arg] = 42
            end

            it "can merge" do
                assert @left.can_semantic_merge?(@right)
                assert @right.can_semantic_merge?(@left)
            end

            it "sets the non-delayed value merge" do
                @left.semantic_merge!(@right)
                assert_equal 42, @left[:arg]
            end

            it "behaves identically if the delayed argument is in the receiver" do
                @right.semantic_merge!(@left)
                assert_equal 42, @right.values[:arg]
            end
        end

        describe "two strong delayed arguments" do
            before do
                @left[:arg]  = flexmock(evaluate_delayed_argument: true, strong?: true)
                @right[:arg] = flexmock(evaluate_delayed_argument: true, strong?: true)
            end

            it "can merge if can_merge? returns true" do
                @left.values[:arg].should_receive(:can_merge?)
                    .with(@left_t, @right_t, @right.values[:arg])
                    .once.and_return(true)
                assert @left.can_semantic_merge?(@right)
            end

            it "sets using the value returned by merge" do
                @left.values[:arg].should_receive(:merge)
                    .with(@left_t, @right_t, @right.values[:arg])
                    .once.and_return(42)
                @left.semantic_merge!(@right)
                assert_equal 42, @left.values[:arg]
            end

            it "returns false if can_merge? returns false" do
                @left.values[:arg].should_receive(:can_merge?)
                    .with(@left_t, @right_t, @right.values[:arg])
                    .once.and_return(false)
                refute @left.can_semantic_merge?(@right)
            end
        end

        describe "one strong delayed argument and one weak delayed argument" do
            before do
                @strong_arg = flexmock(evaluate_delayed_argument: true, strong?: true)
                @left[:arg] = @strong_arg
                @right[:arg] = flexmock(evaluate_delayed_argument: true, strong?: false)
            end

            it "can merge and sets to the strong argument" do
                assert @left.can_semantic_merge?(@right)
                @left.semantic_merge!(@right)
                assert_equal @strong_arg, @left.values[:arg]
            end

            it "behaves identically if the strong side is the argument" do
                assert @right.can_semantic_merge?(@left)
                @right.semantic_merge!(@left)
                assert_equal @strong_arg, @right.values[:arg]
            end
        end

        describe "two weak delayed arguments" do
            before do
                @left[:arg] = flexmock(evaluate_delayed_argument: true, strong?: false)
                @right[:arg] = flexmock(evaluate_delayed_argument: true, strong?: false)
            end

            it "can merge if can_merge? returns true" do
                @left.values[:arg].should_receive(:can_merge?)
                    .with(@left_t, @right_t, @right.values[:arg])
                    .once.and_return(true)
                assert @left.can_semantic_merge?(@right)
            end

            it "sets using the value returned by merge" do
                @left.values[:arg].should_receive(:merge)
                    .with(@left_t, @right_t, @right.values[:arg])
                    .once.and_return(42)
                @left.semantic_merge!(@right)
                assert_equal 42, @left.values[:arg]
            end

            it "returns false if can_merge? returns false" do
                @left.values[:arg].should_receive(:can_merge?)
                    .with(@left_t, @right_t, @right.values[:arg])
                    .once.and_return(false)
                refute @left.can_semantic_merge?(@right)
            end
        end
    end

    describe "#force_merge!" do
        let(:task) do
            task_m = Roby::Task.new_submodel { argument :arg }
            task_m.new arg: 10
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
end

module Roby
    describe DelayedArgumentFromObject do
        attr_reader :task, :arg

        before do
            @task_m = Task.new_submodel { argument(:arg) }
            @task = @task_m.new
            @arg = DelayedArgumentFromObject.new(nil).arg.field
        end

        it "returns a new object when a method is added" do
            inner = flexmock(field: 20)
            root = flexmock(arg: inner)

            root_arg = DelayedArgumentFromObject.new(nil)
            inner_arg = root_arg.arg
            field_arg = inner_arg.field
            assert_equal root, root_arg.evaluate_delayed_argument(root)
            assert_equal inner, inner_arg.evaluate_delayed_argument(root)
            assert_equal 20, field_arg.evaluate_delayed_argument(root)
        end

        it "returns a new object when the type is specified" do
            untyped_arg = DelayedArgumentFromObject.new(nil).field
            typed_arg = untyped_arg.of_type(TrueClass)

            obj = flexmock(field: 20)
            assert_equal 20, untyped_arg.evaluate_delayed_argument(obj)
            catch(:no_value) do
                typed_arg.evaluate_delayed_argument(obj)
            end
        end

        describe "#evaluate_delayed_argument" do
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
                    def evaluate_delayed_argument(task)
                        Struct.new(:field).new(10)
                    end
                end.new
                assert_equal 10, arg.evaluate_delayed_argument(task)
            end
            it "throws no_value if trying to access a delayed task argument that cannot be resolved" do
                task.arg = Class.new do
                    def evaluate_delayed_argument(task)
                        throw :no_value
                    end
                end.new
                assert_throws(:no_value) do
                    arg.evaluate_delayed_argument(task)
                end
            end
        end

        describe "merge behavior" do
            it "is strong" do
                assert @arg.strong?
            end

            it "merges with another delayed argument that resolves to the same value" do
                @task.arg = Struct.new(:field).new(10)
                other_task = @task_m.new
                other_task.arg = Struct.new(:field).new(10)

                assert @arg.can_merge?(@task, other_task, @arg)
                assert_equal 10, @arg.merge(@task, other_task, @arg)
            end

            it "does not merge if the receiver does not resolve" do
                other_task = @task_m.new
                other_task.arg = Struct.new(:field).new(10)

                refute @arg.can_merge?(@task, other_task, @arg)
            end

            it "does not merge if the argument does not resolve" do
                @task.arg = Struct.new(:field).new(10)
                other_task = @task_m.new
                refute @arg.can_merge?(@task, other_task, @arg)
            end

            it "directly returns a static argument if one is given" do
                @task.arg = Struct.new(:field).new(10)
                other_task = @task_m.new
                static_arg = TaskArguments::StaticArgumentWrapper.new(10)
                assert @arg.can_merge?(@task, other_task, static_arg)
                flexmock(@arg).should_receive(:evaluate_delayed_argument).never
                assert_equal 10, @arg.merge(@task, other_task, static_arg)
            end
        end
    end

    describe DelayedArgumentFromState do
        before do
            @state = Roby::OpenStruct.new
        end

        describe "#evaluate_delayed_argument" do
            attr_reader :task, :arg

            before do
                @task_m = Task.new_submodel
                @task = @task_m.new
            end

            it "resolves to a leaf value" do
                @state.some.leaf = 10
                arg = DelayedArgumentFromState.new(@state).some.leaf
                assert_equal 10, arg.evaluate_delayed_argument(@task)
            end
            it "resolves to an intermediate node" do
                @state.some.deep.leaf = 10
                arg = DelayedArgumentFromState.new(@state).some.deep
                assert_equal @state.some.deep, arg.evaluate_delayed_argument(@task)
            end
            it "throws no_value if trying to access a non-existent node" do
                arg = DelayedArgumentFromState.new(@state).some
                assert_throws(:no_value) do
                    arg.evaluate_delayed_argument(task)
                end
            end
        end

        describe "merge behavior" do
            it "is strong" do
                @state.some.deep.leaf = 10
                arg = DelayedArgumentFromState.new(@state).some.deep.leaf
                assert arg.strong?
            end

            it "merges with another delayed argument that resolves to the same value" do
                delayed_arg = flexmock(evaluate_delayed_argument: 10)
                @state.some.deep.leaf = 10
                arg = DelayedArgumentFromState.new(@state).some.deep.leaf
                assert arg.can_merge?(@task, @task, delayed_arg)
                assert_equal 10, arg.merge(@task, @task, delayed_arg)
            end

            it "does not merge with another delayed argument that " \
               "resolves to another value" do
                delayed_arg = flexmock(evaluate_delayed_argument: 20)
                @state.some.deep.leaf = 10
                arg = DelayedArgumentFromState.new(@state).some.deep.leaf
                refute arg.can_merge?(@task, @task, delayed_arg)
            end

            it "does not merge with another delayed argument if " \
               "it cannot be resolved itself" do
                delayed_arg = flexmock(evaluate_delayed_argument: 20)
                arg = DelayedArgumentFromState.new(@state).some.deep.leaf
                refute arg.can_merge?(@task, @task, delayed_arg)
            end

            it "does not merge with another delayed argument if " \
               "that argument cannot resolve" do
                delayed_arg = flexmock
                delayed_arg.should_receive(:evaluate_delayed_argument).and_throw(:no_value)
                @state.some.deep.leaf = 10
                arg = DelayedArgumentFromState.new(@state).some.deep.leaf
                refute arg.can_merge?(@task, @task, delayed_arg)
            end

            it "shortcuts evaluate_delayed_argument if the other arg is a static value" do
                delayed_arg = TaskArguments::StaticArgumentWrapper.new(10)
                @state.some.deep.leaf = 10
                arg = DelayedArgumentFromState.new(@state).some.deep.leaf
                assert arg.can_merge?(@task, @task, delayed_arg)
                flexmock(arg).should_receive(:evaluate_delayed_argument).never
                assert_equal 10, arg.merge(@task, @task, delayed_arg)
            end

            it "merges with another DelayedArgumentFromState " \
               "that point to the same object, with an existing value" do
                @state.some.deep.leaf = 10
                arg0 = DelayedArgumentFromState.new(@state).some.deep.leaf
                arg1 = DelayedArgumentFromState.new(@state).some.deep.leaf
                assert arg0.can_merge?(@task, @task, arg1)
                assert_equal 10, arg0.merge(@task, @task, arg1)
            end

            it "merges with another DelayedArgumentFromState " \
               "that point to the same object, with no value" do
                arg0 = DelayedArgumentFromState.new(@state).some.deep.leaf
                arg1 = DelayedArgumentFromState.new(@state).some.deep.leaf
                assert arg0.can_merge?(@task, @task, arg1)
                assert_equal arg0, arg0.merge(@task, @task, arg1)
            end
        end
    end
end
