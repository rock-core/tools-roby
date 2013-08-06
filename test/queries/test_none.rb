require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Queries::None do
    include Roby::SelfTest

    describe "#===" do
        it "should return false" do
            assert(!(Roby::Queries.none === Object.new))
        end
    end

    it "should be droby-marshallable" do
        assert_same Roby::Queries.any, verify_is_droby_marshallable_object(Roby::Queries.none)
    end
end


