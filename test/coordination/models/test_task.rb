# frozen_string_literal: true

require "roby/test/self"
require "roby/tasks/simple"

describe Roby::Coordination::Models::Task do
    attr_reader :task
    attr_reader :task_model

    before do
        @task_model = flexmock
        @task = Roby::Coordination::Models::Task.new(task_model)
    end

    describe "#find_child" do
        it "returns a Child instance with the given name and provided model if the task model does not respond to #find_child" do
            child = task.find_child("name", child_model = flexmock)
            assert_equal child_model, child.model
            assert_equal task, child.parent
            assert_equal "name", child.role
        end
        it "uses the model returned by task_model.find_child if the task model responds to #find_child" do
            task_model.should_receive(:find_child).with("name").and_return(child_model = flexmock)
            child = task.find_child("name")
            assert_equal child_model, child.model
            assert_equal task, child.parent
            assert_equal "name", child.role
        end
        it "returns nil if the task model responds to #find_child but has no child with the requested name" do
            task_model.should_receive(:find_child).with("name").and_return(nil)
            assert !task.find_child("name")
        end
        it "returns nil if the task model responds to #find_child but has no child with the requested name even if an explicit model name is provided" do
            task_model.should_receive(:find_child).with("name").and_return(nil)
            assert !task.find_child("name", flexmock)
        end
        it "uses the model given as argument even if the task model provides one through #find_child" do
            task_model.should_receive(:find_child).with("name").and_return(flexmock)
            child = task.find_child("name", argument_model = flexmock)
            assert_equal argument_model, child.model
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
