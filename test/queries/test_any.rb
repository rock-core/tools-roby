require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Queries::Any do
    include Roby::SelfTest

    describe "#===" do
        it "should return true" do
            assert (Roby::Queries.any === Object.new)
        end
    end

    it "should be droby-marshallable" do
        assert_same Roby::Queries.any, verify_is_droby_marshallable_object(Roby::Queries.any)
    end
end


