require 'roby/test/self'

module Roby
    module Queries
        describe Index do
            attr_reader :index, :task_m
            before do
                @index = Index.new
                @task_m = Task.new_submodel
            end

            describe "#add" do
                it "registers the model-to-task mapping" do
                    index.add(task = task_m.new)
                    assert_equal [task], index.by_model[task.model].to_a
                end

                it "registers for the whole model ancestry" do
                    flexmock(task = task_m.new).should_receive(model: task.singleton_class)
                    index.add(task)
                    assert_equal [task], index.by_model[task.singleton_class].to_a
                    assert_equal [task], index.by_model[task.model].to_a
                    assert_equal [task], index.by_model[Task].to_a
                    assert_equal [task], index.by_model[TaskService].to_a
                end
            end

            describe "#remove" do
                it "removes the model-to-task mapping" do
                    index.add(task = task_m.new)
                    index.add(other = task_m.new)
                    index.remove(task)
                    assert_equal [other], index.by_model[task_m].to_a
                    assert_equal [other], index.by_model[Task].to_a
                    assert_equal [other], index.by_model[TaskService].to_a
                end

                it "removes a by_model entry when it refers to no tasks anymore" do
                    index.add(task = task_m.new)
                    index.remove(task)
                    refute index.by_model.has_key?(task.class)
                end
            end
        end
    end
end

