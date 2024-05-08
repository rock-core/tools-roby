# frozen_string_literal: true

require "roby/test/self"

module Roby
    describe DistributedObject do
        before do
            @object = DistributedObject.new
            flexmock(@object).should_receive(:local_owner_id).and_return(@local_owner_id = flexmock)
        end

        describe "#self_owned?" do
            it "is self_owned on creation" do
                assert @object.self_owned?
            end

            it "is not self_owned as soon as an owner is added" do
                @object.add_owner(flexmock)
                refute @object.self_owned?
            end

            it "remains self_owned if the local owner ID was explicitely added" do
                @object.add_owner(@local_owner_id)
                @object.add_owner(flexmock)
                assert @object.self_owned?
            end

            it "becomes self_owned again if the local owner ID is explicitely added" do
                @object.add_owner(flexmock)
                @object.add_owner(@local_owner_id)
                assert @object.self_owned?
            end

            it "is not self_owned if the local owner ID is added and removed while other owners are set" do
                @object.add_owner(flexmock)
                @object.add_owner(@local_owner_id)
                @object.remove_owner(@local_owner_id)
                refute @object.self_owned?
            end

            it "becomes self_owned if all owners are removed one-by-one" do
                @object.add_owner(owner = flexmock)
                @object.remove_owner(owner)
                assert @object.self_owned?
            end

            it "becomes self_owned if all owners are removed with clear_owners" do
                @object.add_owner(flexmock)
                @object.clear_owners
                assert @object.self_owned?
            end
        end

        describe "#owned_by?" do
            it "is owned by the local peer if #self_owned? returns true" do
                flexmock(@object).should_receive(:self_owned?).and_return(true)
                assert @object.owned_by?(@local_owner_id)
            end
            it "is not owned by the local peer if #self_owned? returns false" do
                flexmock(@object).should_receive(:self_owned?).and_return(false)
                refute @object.owned_by?(@local_owner_id)
            end
            it "is owned by an explicitly added owner" do
                @object.add_owner(owner = flexmock)
                assert @object.owned_by?(owner)
            end
            it "is not owned by an arbitrary owner" do
                refute @object.owned_by?(flexmock)
            end
        end
    end
end
