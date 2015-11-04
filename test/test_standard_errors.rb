require 'roby/test/self'

module Roby
    describe UntypedLocalizedError do
        describe "#kind_of?" do
            it "resolves based on the actual exception class" do
                plan.add(task = Roby::Task.new)
                klass = Class.new(LocalizedError)

                untyped = UntypedLocalizedError.new(task)
                untyped.exception_class = klass
                assert untyped.kind_of?(LocalizedError)
                assert untyped.kind_of?(klass)
                assert !untyped.kind_of?(UntypedLocalizedError)
            end
        end
    end
end

