require 'roby/test/self'

module Roby
    module Queries
        describe ExecutionExceptionMatcher do
            describe "#handled" do
                attr_reader :localized_error_m, :matcher, :error
                before do
                    @localized_error_m = Class.new(LocalizedError)
                    @matcher = localized_error_m.to_execution_exception_matcher
                    task = Roby::Task.new
                    @error   = localized_error_m.new(task).to_execution_exception
                end

                it "matches both handled and unhandled exceptions if unset" do
                    assert(matcher === error)
                    error.handled = true
                    assert(matcher === error)
                end
                it "matches both handled and unhandled exceptions if explicitley set to nil" do
                    matcher.handled(nil)
                    assert(matcher === error)
                    error.handled = true
                    assert(matcher === error)
                end
                it "matches only handled exceptions if set" do
                    matcher.handled
                    refute(matcher === error)
                    error.handled = true
                    assert(matcher === error)
                end
                it "matches only unhandled exceptions if set to false" do
                    matcher.not_handled
                    assert(matcher === error)
                    error.handled = true
                    refute(matcher === error)
                end
            end

            describe "#with_trace" do
                before do
                    plan.add(@child = Roby::Task.new)
                    plan.add(@root0 = Roby::Task.new)
                    plan.add(@root1 = Roby::Task.new)
                end

                describe "matching trace" do
                    it "matches the trace" do
                        ee = ExecutionException.new(LocalizedError.new(@child))
                        ee.propagate @child, @root0
                        ee.propagate @child, @root1
                        assert(LocalizedError.to_execution_exception_matcher.with_trace(@child, @root0, @child, @root1) === ee)
                        assert(LocalizedError.to_execution_exception_matcher.with_trace(@child => [@root0, @root1]) === ee)
                    end

                    it "matches the trace as a hash without a shared parent" do
                        ee = ExecutionException.new(LocalizedError.new(@child))
                        ee.propagate @child, @root0
                        assert(LocalizedError.to_execution_exception_matcher.with_trace(@child, @root0) === ee)
                        assert(LocalizedError.to_execution_exception_matcher.with_trace(@child => [@root0]) === ee)
                        assert(LocalizedError.to_execution_exception_matcher.with_trace(@child => @root0) === ee)
                    end
                end

                describe "not matching the trace" do
                    it "does not match if the expected trace does not contain an edge of the actual trace" do
                        ee = ExecutionException.new(LocalizedError.new(@child))
                        ee.propagate @child, @root0
                        ee.propagate @child, @root1
                        refute(LocalizedError.to_execution_exception_matcher.with_trace(@child, @root0) === ee)
                        refute(LocalizedError.to_execution_exception_matcher.with_trace(@child => @root0) === ee)
                        refute(LocalizedError.to_execution_exception_matcher.with_trace(@child => [@root0]) === ee)
                    end

                    it "does not match if the expected trace contains an edge that the actual trace does not have" do
                        ee = ExecutionException.new(LocalizedError.new(@child))
                        ee.propagate @child, @root0
                        refute(LocalizedError.to_execution_exception_matcher.with_trace(@child, @root0, @child, @root1) === ee)
                        refute(LocalizedError.to_execution_exception_matcher.with_trace(@child => [@root0, @root1]) === ee)
                    end
                end
            end
        end
    end
end

