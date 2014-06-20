require 'roby/test/self'
require 'roby/tasks/simple'

describe Roby::Queries::LocalizedErrorMatcher do
    describe "#===" do
        attr_reader :task_model, :task
        before do
            @task_model = Roby::Task.new_submodel
            plan.add(@task = task_model.new)
        end

        it "should match any localized error by default" do
            error = Roby::LocalizedError.new(task)
            assert(Roby::LocalizedError.match === error)
        end
        it "should return true if the error type matches" do
            error = Roby::LocalizedError.new(task)
            model_match = flexmock
            model_match.should_receive(:===).with(error.class).and_return(true)
            assert (Roby::LocalizedError.match.with_model(model_match) === error)
        end
        it "should return false if the error type does not match" do
            error = Roby::LocalizedError.new(task)
            model_match = flexmock
            model_match.should_receive(:===).with(error.class).and_return(false)
            assert !(Roby::LocalizedError.match.with_model(model_match) === error)
        end
        it "should match the generator origin if the origin matcher responds to task_matcher" do
            error = Roby::LocalizedError.new(task.success_event)
            origin_match = flexmock
            origin_match.should_receive(:task_matcher).and_return(origin_match)
            origin_match.should_receive(:match).and_return(origin_match)
            origin_match.should_receive(:===).with(task.success_event).and_return(true).once
            assert (Roby::LocalizedError.match.with_origin(origin_match) === error)
        end
        it "should return false if given a generator matcher and the error originates only from a task" do
            error = Roby::LocalizedError.new(task)
            origin_match = flexmock
            origin_match.should_receive(:task_matcher).and_return(origin_match)
            origin_match.should_receive(:match).and_return(origin_match)
            assert !(Roby::LocalizedError.match.with_origin(origin_match) === error)
        end
        it "should match the task origin if the origin matcher responds to task_matcher" do
            error = Roby::LocalizedError.new(task)
            origin_match = flexmock
            origin_match.should_receive(:match).and_return(origin_match)
            origin_match.should_receive(:===).with(task).and_return(true).once
            assert (Roby::LocalizedError.match.with_origin(origin_match) === error)
        end
        it "should make event generator matchers generalized by default" do
            origin = Roby::Task.success_event
            matcher = Roby::LocalizedError.match.with_origin(origin)
            assert matcher.failure_point_matcher.generalized?
        end
        it "should allow event generator origin matchers to be explicitly set to be restrictive in matching" do
            origin = Roby::Task.success_event.match
            matcher = Roby::LocalizedError.match.with_origin(origin)
            assert !matcher.failure_point_matcher.generalized?
        end
    end
    describe "droby marshalling" do
        it "should be dump-able" do
            origin = Roby::Task.success_event.match
            matcher = Roby::LocalizedError.match.with_origin(origin)
            verify_is_droby_marshallable_object(matcher)
        end
    end
end


