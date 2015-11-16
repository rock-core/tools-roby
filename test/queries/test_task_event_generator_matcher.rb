require 'roby/test/self'
require 'roby/tasks/simple'

describe Roby::Queries::TaskEventGeneratorMatcher do
    describe "in not generalized mode" do
        describe "#===" do
            attr_reader :task_matcher, :task, :generator
            before do
                @task_matcher = flexmock
                @task = flexmock
                event_model = Roby::TaskEvent.new_submodel(symbol: :dummy)
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
            it "should return false if the task matcher returns true but the symbol does not match" do
                task_matcher.should_receive(:===).with(task).and_return(true)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher, 'bla')
                assert !(matcher === generator)
            end
            it "should return true if the task matcher returns true and the symbol matches" do
                task_matcher.should_receive(:===).with(task).and_return(true)
                symbol_match = flexmock
                symbol_match.should_receive(:===).with('dummy').and_return(true)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher, symbol_match)
                assert (matcher === generator)
            end
        end
    end

    describe "in generalized mode" do
        describe "#===" do
            attr_reader :task_matcher, :task, :generator, :source_generator, :symbol_match
            before do
                @task_matcher = flexmock
                plan.add(@task = Roby::Task.new)
                @generator = task.stop_event

                plan.add(other_task = Roby::Task.new)
                @source_generator = other_task.failed_event
                other_task.stop_event.forward_to task.stop_event
                task_matcher.should_receive(:===).with(other_task).and_return(false)

            end

            it "should return false if the task matcher returns false" do
                task_matcher.should_receive(:===).with(task).and_return(false)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher).generalized
                assert !(matcher === generator)
            end
            it "should return true if the task matcher returns true and the symbol match is default" do
                task_matcher.should_receive(:===).with(task).and_return(true)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher).generalized
                assert (matcher === generator)
            end
            it "should return false if the task matcher returns true but the symbol does not match" do
                task_matcher.should_receive(:===).with(task).and_return(true)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher, 'bla').generalized
                assert !(matcher === generator)
            end
            it "should return true if the task matcher returns true and the symbol matches" do
                task_matcher.should_receive(:===).with(task).and_return(true)
                symbol_match = flexmock
                symbol_match.should_receive(:===).with('stop').and_return(true)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher, symbol_match).generalized
                assert (matcher === generator)
            end
            it "should return false if it is forwarded to another task for which the task matcher returns false" do
                task_matcher.should_receive(:===).with(task).and_return(false)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher).generalized
                assert !(matcher === source_generator)
            end
            it "should return true if it is forwarded to another task for which the task matcher returns true and the symbol match is default" do
                task_matcher.should_receive(:===).with(task).and_return(true)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher).generalized
                assert (matcher === source_generator)
            end
            it "should return false if it is forwarded to another task for which the task matcher returns true but the symbol does not match" do
                task_matcher.should_receive(:===).with(task).and_return(true)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher, 'bla').generalized
                assert !(matcher === source_generator)
            end
            it "should return true if it is forwarded to another task for which the task matcher returns true and the symbol matches" do
                task_matcher.should_receive(:===).with(task).and_return(true)
                @symbol_match = flexmock
                symbol_match.should_receive(:===).with('failed').and_return(false)
                symbol_match.should_receive(:===).with('failed').and_return(false)
                symbol_match.should_receive(:===).with('stop').and_return(true)
                matcher = Roby::Queries::TaskEventGeneratorMatcher.new(task_matcher, symbol_match).generalized
                assert (matcher === source_generator)
            end
        end
    end
end
