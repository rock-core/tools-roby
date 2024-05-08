# frozen_string_literal: true

require "roby/test/self"

module Roby
    module DRoby
        describe DRobyID do
            it "#== compares using the ID object" do
                id = Object.new
                assert_equal DRobyID.new(id), DRobyID.new(id)
                refute_equal DRobyID.new(Object.new), DRobyID.new(id)
            end

            it "#eql? compares using the ID object" do
                id = Object.new
                assert DRobyID.new(id).eql?(DRobyID.new(id))
                refute DRobyID.new(Object.new).eql?(DRobyID.new(id))
            end

            it "is suitable as a hash key" do
                id = Object.new
                h = { DRobyID.new(id) => 10 }
                assert h.has_key?(DRobyID.new(id))
                refute h.has_key?(DRobyID.new(Object.new))
            end

            describe ".allocate" do
                it "creates IDs using an ever-increasing counter" do
                    id0 = DRobyID.allocate
                    id1 = DRobyID.allocate
                    assert_equal id1.id, id0.id + 1
                end
            end
        end
    end
end
