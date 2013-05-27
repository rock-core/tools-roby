require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Queries::Any do
    include Roby::SelfTest

    describe "#===" do
        it "should return true" do
            assert (Roby::Queries.any === Object.new)
        end
    end
end


