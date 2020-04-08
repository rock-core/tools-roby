# frozen_string_literal: true

require "roby/test/self"
require "roby/tasks/simple"

describe Roby::Coordination::TaskBase do
    attr_reader :base
    attr_reader :task
    attr_reader :model_task

    before do
        @base = flexmock
        base.should_receive(:instance_for).by_default
        @model_task = flexmock
        model_task.should_receive(:find_child_model).by_default
        model_task.should_receive(:find_child).by_default
        @task = Roby::Coordination::TaskBase.new(base, model_task)
        flexmock(task).should_receive(:resolve).and_raise(Roby::Coordination::ResolvingUnboundObject).by_default
    end

    describe "#find_child" do
        it "returns a task instance after having resolved the task model using model.find_child" do
            model_task.should_receive(:find_child).with("name", any).and_return(model_child = flexmock)
            base.should_receive(:instance_for).with(model_child).and_return(instance = flexmock)
            assert_equal instance, task.find_child("name")
        end
        it "resolves the child model from the task instance if already bound and if the model does not provide this information" do
            roby_task, roby_child = prepare_plan add: 2, model: Roby::Tasks::Simple
            roby_task.depends_on roby_child, role: "name"
            model_task.should_receive(:find_child_model).and_return(nil)
            model_task.should_receive(:find_child).once
                .with("name", Roby::Tasks::Simple)
            flexmock(task).should_receive(:resolve).and_return(roby_task)
            task.find_child("name")
        end
        it "does not resolve the child model from the task instance if already bound and if the model already provides this information" do
            roby_task, roby_child = prepare_plan add: 2, model: Roby::Tasks::Simple
            roby_task.depends_on roby_child, role: "name"
            model_task.should_receive(:find_child_model).with("name").and_return(child_model = flexmock)
            model_task.should_receive(:find_child).once
                .with("name", child_model)
            flexmock(task).should_receive(:resolve).and_return(roby_task)
            task.find_child("name")
        end
        it "uses the provided child model if one is given, even if a task instance exists" do
            roby_task, roby_child = prepare_plan add: 2, model: Roby::Tasks::Simple
            roby_task.depends_on roby_child, role: "name"

            roby_child_model = flexmock
            model_task.should_receive(:find_child).once
                .with("name", roby_child_model)
            flexmock(task).should_receive(:resolve).and_return(roby_task)
            task.find_child("name", roby_child_model)
        end
        it "returns nil for nonexistent children" do
            model_task.should_receive(:find_child).and_return(nil)
            assert !task.find_child("name")
        end
    end

    it "gives access to children using the _child methods" do
        flexmock(task).should_receive(:find_child).with("child_name").and_return(child = Object.new).once
        assert_equal child, task.child_name_child
    end
    it "raises ArgumentError if a _child method is called with arguments" do
        flexmock(task).should_receive(:find_child).never
        assert_raises(ArgumentError) { task.child_name_child("arg") }
    end
    it "raises NoMethodError if a _child method is called for a child that does not exist" do
        flexmock(task).should_receive(:find_child).with("child_name").and_return(nil)
        assert_raises(NoMethodError) { task.child_name_child }
    end
    it "gives access to events using the _event methods" do
        flexmock(task).should_receive(:find_event).with("name").and_return(child = Object.new).once
        assert_equal child, task.name_event
    end
    it "raises ArgumentError if a _event method is called with arguments" do
        flexmock(task).should_receive(:find_event).never
        assert_raises(ArgumentError) { task.name_event("arg") }
    end
    it "raises NoMethodError if a _event method is called for a child that does not exist" do
        flexmock(task).should_receive(:find_event).with("name").and_return(nil)
        assert_raises(NoMethodError) { task.name_event }
    end
end
