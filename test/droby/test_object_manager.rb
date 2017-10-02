require 'roby/test/self'

module Roby
    module DRoby
        describe ObjectManager do
            let(:local_id) { Object.new }
            subject { ObjectManager.new(local_id) }

            describe "#register_siblings" do
                it "registers the siblings of an object for further resolution" do
                    obj = flexmock(droby_id: flexmock)
                    peer_id, sibling_id = flexmock, flexmock
                    subject.register_siblings(obj, peer_id => sibling_id)
                    peer_id_2, sibling_id_2 = flexmock, flexmock
                    subject.register_siblings(obj, peer_id_2 => sibling_id_2)
                    assert_equal Hash[peer_id => sibling_id, peer_id_2 => sibling_id_2],
                        subject.known_siblings_for(obj)
                end
            end

            describe "#deregister_siblings" do
                it "deregisters the siblings of an object" do
                    obj = flexmock(droby_id: flexmock)
                    peer_id, sibling_id = flexmock, flexmock
                    subject.register_siblings(obj, peer_id => sibling_id)
                    peer_id_2, sibling_id_2 = flexmock, flexmock
                    subject.register_siblings(obj, peer_id_2 => sibling_id_2)

                    subject.deregister_siblings(obj, peer_id_2 => sibling_id_2)
                    assert_equal Hash[peer_id => sibling_id], subject.known_siblings_for(obj)
                    assert subject.include?(obj)
                end

                it "removes all references to the object if the last siblings have been removed" do
                    obj, peer_id, sibling_id = flexmock(droby_id: flexmock), flexmock, flexmock
                    subject.register_siblings(obj, peer_id => sibling_id)
                    subject.deregister_siblings(obj, peer_id => sibling_id)
                    assert !subject.include?(obj)
                end
                
                it "raises ArgumentError if the siblings that are being removed do not match the registered ones" do
                    obj, peer_id, sibling_id = flexmock(droby_id: flexmock), flexmock, flexmock
                    subject.register_siblings(obj, peer_id => sibling_id)
                    assert_raises(ArgumentError) do
                        subject.deregister_siblings(obj, peer_id => flexmock)
                    end
                end
            end

            describe "#register_object" do
                it "registers the siblings given as well as the local object's ID" do
                    droby_id, siblings = flexmock, flexmock
                    local_object = flexmock(droby_id: droby_id)
                    flexmock(subject).should_receive(:register_siblings).with(local_object, local_id => droby_id).once
                    flexmock(subject).should_receive(:register_siblings).with(local_object, siblings).once
                    subject.register_object(local_object, siblings)
                end
            end

            describe "#deregister_object" do
                it "removes all references to the object" do
                    droby_id, peer_id, sibling_id = flexmock, flexmock, flexmock
                    local_object = flexmock(droby_id: droby_id)
                    subject.register_object(local_object, peer_id => sibling_id)
                    subject.deregister_object(local_object)
                    assert_equal Hash.new, subject.known_siblings_for(local_object)
                    assert !subject.find_by_id(peer_id, sibling_id)
                end

                it "deregisters models from the name-to-model mapping" do
                    subject.register_model(m = flexmock(name: 'Test', droby_id: Object.new))
                    subject.deregister_object(m)
                    assert !subject.find_model_by_name('Test')
                end
            end

            describe "#find_by_id" do
                it "returns the object's known sibling on the peer" do
                    droby_id, peer_id, sibling_id = flexmock, flexmock, flexmock
                    local_object = flexmock(droby_id: droby_id)
                    subject.register_object(local_object, peer_id => sibling_id)
                    assert_equal local_object, subject.find_by_id(peer_id, sibling_id)
                end

                it "returns nil for an unknown object" do
                    assert_nil subject.find_by_id(flexmock, flexmock)
                end

                it "returns nil for a known peer but an unknwon DRobyID on that peer" do
                    droby_id, peer_id, sibling_id = flexmock, flexmock, flexmock
                    local_object = flexmock(droby_id: droby_id)
                    subject.register_object(local_object, peer_id => sibling_id)
                    assert_nil subject.find_by_id(peer_id, flexmock)
                end
            end

            describe "#fetch_by_id" do
                it "returns the object's known sibling on the peer" do
                    peer_id, sibling_id = flexmock, flexmock
                    flexmock(subject).should_receive(:find_by_id).with(peer_id, sibling_id).
                        and_return(obj = flexmock)
                    assert_equal obj, subject.fetch_by_id(peer_id, sibling_id)
                end

                it "raises UnknownSibling for an object that cannot be resolved" do
                    flexmock(subject).should_receive(:find_by_id).
                        and_return(nil)
                    assert_raises(UnknownSibling) do
                        subject.fetch_by_id(flexmock, flexmock)
                    end
                end

                it "returns nil for a known peer but an unknwon DRobyID on that peer" do
                    droby_id, peer_id, sibling_id = flexmock, flexmock, flexmock
                    local_object = flexmock(droby_id: droby_id)
                    subject.register_object(local_object, peer_id => sibling_id)
                    assert_nil subject.find_by_id(peer_id, flexmock)
                end
            end

            describe "#include?" do
                it "returns false on an arbitrary object" do
                    obj = flexmock(droby_id: flexmock)
                    assert !subject.include?(obj)
                end

                it "returns true on an object with registered siblings" do
                    obj, peer_id, sibling_id = flexmock(droby_id: flexmock), flexmock, flexmock
                    subject.register_siblings(obj, peer_id => sibling_id)
                    assert subject.include?(obj)
                end
            end

            describe "#find_model_by_name" do
                it "resolves by name a model already registered by #register_model" do
                    model = flexmock(name: 'Test', droby_id: Object.new)
                    subject.register_model(model)
                    assert_equal model, subject.find_model_by_name('Test')
                end

                it "returns nil for a non-registered model" do
                    assert !subject.find_model_by_name('Test')
                end
            end

            describe "#register_model" do
                it "does not register models that have no name" do
                    model = flexmock(name: nil)
                    flexmock(subject).should_receive(:register_object).with(model, Hash).once
                    subject.register_model(model)
                    refute subject.find_model_by_name(nil)
                end

                it "allows to pass a name explicitly" do
                    model = flexmock(name: nil)
                    flexmock(subject).should_receive(:register_object).with(model, Hash).once
                    subject.register_model(model, name: 'test')
                    assert subject.find_model_by_name('test')
                end
            end
        end
    end
end

