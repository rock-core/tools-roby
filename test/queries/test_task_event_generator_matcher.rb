require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Queries::TaskEventGeneratorMatcher do
    include Roby::SelfTest

    describe "#===" do
        attr_reader :task_matcher, :task, :generator
        before do
            @task_matcher = flexmock
            @task = flexmock
            event_model = Roby::TaskEvent.new_submodel
            @generator = Roby::TaskEventGenerator.new(task, event_model)
        end

        it "should return false if the task matcher returns false" do
            task_matcher.should_receive(:===).with(task).and_return(false)
            matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher)
            assert !(matcher === generator)
        end
        it "should return true if the task matcher returns true and the symbol match is default" do
            task_matcher.should_receive(:===).with(task).and_return(true)
            matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher)
            assert (matcher === generator)
        end
    end
end
