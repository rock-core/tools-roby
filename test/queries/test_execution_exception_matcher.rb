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
        end
    end
end

