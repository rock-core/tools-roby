require 'roby/test/self'
require 'roby/tasks/simple'

describe Roby::Queries::None do
    describe "#===" do
        it "should return false" do
            assert(!(Roby::Queries.none === Object.new))
        end
    end

    it "should be droby-marshallable" do
        assert_same Roby::Queries.none, verify_is_droby_marshallable_object(Roby::Queries.none)
    end
end


