require 'roby/test/self'
require 'roby/tasks/simple'

describe Roby::Queries::None do
    describe "#===" do
        it "should return false" do
            assert(!(Roby::Queries.none === Object.new))
        end
    end
end


