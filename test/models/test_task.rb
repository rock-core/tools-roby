# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Models
        describe Task do
            it "registers its submodels on the Task class" do
                subclass = Roby::Task.new_submodel
                assert_equal Roby::Task, subclass.supermodel
                assert Roby::Task.each_submodel.to_a.include?(subclass)
            end

            it "provides task services" do
                tag = TaskService.new_submodel
                task = Roby::Task.new_submodel
                task.provides tag
                assert task.fullfills?(tag)
            end

            it "has the arguments of provided task services" do
                tag = TaskService.new_submodel { argument :service_arg }
                task = Roby::Task.new_submodel
                task.provides tag
                assert task.has_argument?(:service_arg)
            end

            describe "abstract-ness" do
                describe Roby::Task do
                    it "is abstract" do
                        assert Roby::Task.abstract?
                    end
                end

                it "does not define submodels as abstract by default" do
                    assert !Roby::Task.new_submodel.abstract?
                end

                it "uses #abstract to mark models as abstract" do
                    submodel = Roby::Task.new_submodel
                    submodel.abstract
                    assert submodel.abstract?
                end
            end

            describe "access to events" do
                it "gives access through the _event method suffix" do
                    model = Roby::Task.new_submodel do
                        event :custom
                        event :other
                    end
                    event_model = model.custom_event
                    assert_same model.find_event_model("custom"), event_model
                end
            end

            describe "#with_arguments" do
                it "returns a proxy object whose #as_plan method creates a task with arguments set" do
                    model = Tasks::Simple.new_submodel
                    task = model.with_arguments(id: 20).as_plan
                    assert_kind_of model, task
                    assert_equal 20, task.arguments[:id]
                end
            end

            describe "#event" do
                attr_reader :task_m

                before do
                    @task_m = Tasks::Simple.new_submodel
                end

                it "validates the block arity" do
                    assert_raises(ArgumentError) { task_m.event(:start) { |a, b| } }
                    assert_raises(ArgumentError) { task_m.event(:start) {} }
                    task_m.event(:start) { |*| }
                end
            end

            describe "#on_exception" do
                attr_reader :task_m

                before do
                    @task_m = Tasks::Simple.new_submodel
                end

                it "validates the block arity" do
                    assert_raises(ArgumentError) { task_m.on_exception(LocalizedError) { |a, b| } }
                    assert_raises(ArgumentError) { task_m.on_exception(LocalizedError) {} }
                    task_m.on_exception(LocalizedError) { |*| }
                end
            end

            describe "#on" do
                attr_reader :task_m

                before do
                    @task_m = Tasks::Simple.new_submodel
                end

                it "validates the block arity" do
                    assert_raises(ArgumentError) { task_m.on(:start) { |a, b| } }
                    assert_raises(ArgumentError) { task_m.on(:start) {} }
                    task_m.on(:start) { |*| }
                end
            end
        end
    end
end
