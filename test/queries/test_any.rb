require 'roby/test/self'
require 'roby/tasks/simple'

describe Roby::Queries::Any do
    describe "#===" do
        it "should return true" do
            assert (Roby::Queries.any === Object.new)
        end
    end
end


