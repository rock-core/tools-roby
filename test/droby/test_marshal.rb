require 'roby/test/self'

module Roby
    module DRoby
        class ModelTestResolutionByName
        end

        class IdentifiableObject
            include Identifiable
            # To please flexmock strict mode
            def droby_dump(peer); raise NotImplementedError end
        end

        describe Marshal do
            let(:local_id) { Object.new }
            let(:remote_id) { Object.new }
            let(:remote_object_id) { Object.new }
            let(:object_manager) { ObjectManager.new(local_id) }
            subject { Marshal.new(object_manager, remote_id) }

            describe "#dump" do
                it "returns the ID of the remote sibling if one is known" do
                    obj = flexmock(droby_dump: 10, droby_id: Object.new)
                    object_manager.register_object(obj, remote_id => remote_object_id)
                    assert_equal RemoteDRobyID.new(remote_id, remote_object_id),
                        subject.dump(obj)
                end

                it "returns the plain object if the object does not define #droby_dump" do
                    obj = flexmock
                    assert_equal obj, subject.dump(obj)
                end

                it "returns the result of #droby_dump if it responds to it" do
                    marshalled = flexmock
                    obj = flexmock(droby_dump: marshalled)
                    assert_equal marshalled, subject.dump(obj)
                end
            end

            describe "#find_local_object" do
                it "does not resolve objects that respond to #proxy" do
                    obj = flexmock
                    obj.should_receive(:proxy).never
                    assert_equal [false, nil], subject.find_local_object(obj)
                end

                it "returns plain objects as-is" do
                    assert_equal [true, 10], subject.find_local_object(10)
                    obj = flexmock
                    assert_equal [true, obj], subject.find_local_object(obj)
                end

                it "resolves RemoteDRobyID objects" do
                    remote_droby_id = RemoteDRobyID.new(remote_id, remote_object_id)
                    flexmock(object_manager).should_receive(:fetch_by_id).
                        with(remote_id, remote_object_id).once.and_return(obj = flexmock)
                    assert_equal [true, obj], subject.find_local_object(remote_droby_id)
                end

                it "raises if a RemoteDRobyID cannot be resolved" do
                    remote_droby_id = RemoteDRobyID.new(remote_id, remote_object_id)
                    assert_raises(UnknownSibling) do
                        subject.find_local_object(remote_droby_id)
                    end
                end

                it "attempts to resolve distributed objects through their siblings" do
                    marshalled = flexmock(remote_siblings: Hash[remote_id => remote_object_id])
                    flexmock(object_manager).should_receive(:find_by_id).
                        with(remote_id, remote_object_id).once.and_return(obj = flexmock(droby_id: Object.new))
                    assert_equal [true, obj], subject.find_local_object(marshalled)
                end

                it "returns (false, nil) if none of the siblings can be resolved" do
                    marshalled = flexmock(remote_siblings: Hash[remote_id => remote_object_id])
                    assert_equal [false, nil], subject.find_local_object(marshalled)
                end

                it "registers the siblings of newly discovered objects" do
                    marshalled = flexmock(remote_siblings: Hash[remote_id => remote_object_id])
                    flexmock(object_manager, :strict).should_receive(:find_by_id).
                        with(remote_id, remote_object_id).and_return(obj = flexmock)
                    flexmock(object_manager, :strict).should_receive(:register_siblings).
                        once.with(obj, remote_id => remote_object_id)
                    assert_equal [true, obj], subject.find_local_object(marshalled)
                end

                it "calls #update on the objects resolved by remote_siblings" do
                    marshalled = flexmock(remote_siblings: Hash[remote_id => remote_object_id])
                    flexmock(object_manager, :strict).should_receive(:find_by_id).
                        with(remote_id, remote_object_id).and_return(obj = flexmock(droby_id: Object.new))
                    flexmock(marshalled).should_receive(:update).with(subject, obj).once
                    assert_equal [true, obj], subject.find_local_object(marshalled)
                end

                it "resolves nil" do
                    assert_equal [true, nil], subject.find_local_object(nil)
                end
            end

            describe "#local_object" do
                it "returns an object resolved by #find_local_object" do
                    flexmock(subject).should_receive(:find_local_object).
                        and_return([true, obj = flexmock])
                    assert_equal obj, subject.local_object(nil)
                end

                describe "the handling of unknown distributed objects" do
                    let(:local_object) { flexmock(droby_id: Object.new) }
                    before do
                        flexmock(subject).should_receive(:find_local_object).
                            and_return([false, nil])
                    end

                    it "raises NoLocalObject if create is false and one attempts to resolve an unknown distributed object" do
                        assert_raises(NoLocalObject) do
                            subject.local_object(flexmock(remote_siblings: Hash.new), create: false)
                        end
                    end

                    it "proxies a an unknown distributed object if create is true" do
                        marshalled = flexmock(remote_siblings: Hash.new)
                        marshalled.should_receive(:proxy).and_return(local_object)
                        assert_equal local_object, subject.local_object(marshalled, create: true)
                    end

                    it "registers proxied distributed objects if create is true" do
                        marshalled = flexmock(remote_siblings: flexmock, proxy: local_object)
                        flexmock(object_manager, :strict).
                            should_receive(:register_object).with(local_object, marshalled.remote_siblings).
                            once
                        subject.local_object(marshalled, create: true)
                    end

                    it "calls #update on the marshalled object" do
                        marshalled = flexmock(remote_siblings: Hash.new, proxy: local_object)
                        marshalled.should_receive(:update).with(subject, local_object, fresh_proxy: true).once
                        subject.local_object(marshalled, create: true)
                    end
                end

                it "calls #proxy on non-distributed objects that define it" do
                    marshalled = flexmock
                    marshalled.should_receive(:proxy).with(subject).
                        and_return(local_object = flexmock)
                    assert_equal local_object, subject.local_object(marshalled, create: true)
                end

                it "raises if #find_local_object fails and the object cannot be resolved/created as a distributed object" do
                    flexmock(subject).should_receive(:find_local_object).
                        and_return([false, nil])
                    marshalled = flexmock
                    assert_raises(NoLocalObject) do
                        subject.local_object(marshalled)
                    end
                end
            end

            describe "#find_local_model" do
                let(:marshalled) { flexmock }
                it "resolves it as an object first" do
                    flexmock(subject).should_receive(:find_local_object).with(marshalled).
                        and_return([true, obj = flexmock])
                    assert_equal obj, subject.find_local_model(marshalled)
                end

                it "resolves the model by name if resolution by ID fails" do
                    flexmock(subject).should_receive(:find_local_object).with(marshalled).
                        and_return([false, nil])
                    model = flexmock(name: 'Test', droby_id: Object.new)
                    subject.object_manager.register_model(model)
                    marshalled.should_receive(name: 'Test')
                    assert_equal model, subject.find_local_model(marshalled)
                end

                it "attempts to resolve the model in the constant hierarchy" do
                    flexmock(subject).should_receive(:find_local_object).
                        and_return([false, nil])
                    marshalled.should_receive(name: 'Roby::DRoby::ModelTestResolutionByName')
                    assert_equal ModelTestResolutionByName, subject.find_local_model(marshalled)
                end

                it "returns nil if the name cannot be resolved" do
                    flexmock(subject).should_receive(:find_local_object).
                        and_return([false, nil])
                    marshalled.should_receive(name: 'Roby::Does::Not::Exist')
                    assert_equal nil, subject.find_local_model(marshalled)
                end
            end

            describe "#dump_groups" do
                it "use IDs to dump the group objects within the group's #droby_dump calls" do
                    obj0, obj1 = IdentifiableObject.new, IdentifiableObject.new
                    flexmock(obj0).should_receive(:droby_dump).
                        and_return { subject.dump(obj1) }
                    flexmock(obj1).should_receive(:droby_dump).
                        and_return { 42 }

                    m_obj0, m_obj1 = subject.dump_groups([obj0], [obj1])
                    assert_equal [obj0.droby_id, obj1.droby_id], m_obj0
                    assert_equal [obj1.droby_id, 42], m_obj1
                end

                it "passes the mapped objects to a block if one is given" do
                    obj0, obj1 = IdentifiableObject.new, IdentifiableObject.new
                    flexmock(obj0, droby_dump: 24)
                    flexmock(obj1, droby_dump: 42)
                    subject.dump_groups([obj0], [obj1]) do |m_obj0, m_obj1|
                        assert_equal [obj0.droby_id, 24], m_obj0
                        assert_equal [obj1.droby_id, 42], m_obj1
                    end
                end

                it "use IDs to dump the objects from within the block" do
                    obj0, obj1 = IdentifiableObject.new, IdentifiableObject.new
                    flexmock(obj0, droby_dump: 24)
                    flexmock(obj1, droby_dump: 42)

                    subject.dump_groups([obj0], [obj1]) do
                        assert_equal obj0.droby_id, subject.dump(obj0)
                        assert_equal obj1.droby_id, subject.dump(obj1)
                    end
                end

                it "returns the block's return value" do
                    obj0, obj1 = IdentifiableObject.new, IdentifiableObject.new
                    flexmock(obj0, droby_dump: 24)
                    flexmock(obj1, droby_dump: 42)

                    ret = subject.dump_groups([obj0], [obj1]) do
                        42
                    end
                    assert_equal 42, ret
                end

                it "does not use IDs to dump the objects when it returned" do
                    obj0, obj1 = IdentifiableObject.new, IdentifiableObject.new
                    flexmock(obj0, droby_dump: 24)
                    flexmock(obj1, droby_dump: 42)
                    subject.dump_groups([obj0], [obj1]) do
                    end
                    assert_equal 24, subject.dump(obj0)
                end
            end

            describe "#load_groups" do
                it "resolves the group IDs to objects the within the group's #proxy calls" do
                    m_obj0, m_obj1 = flexmock, flexmock
                    proxy0 = Class.new do
                        attr_accessor :value
                    end.new
                    m_obj0.should_receive(:proxy).and_return  { proxy0 }
                    m_obj0.should_receive(:update).and_return { proxy0.value = subject.local_object(2) }
                    m_obj1.should_receive(:proxy).and_return { 42 }

                    obj0, obj1 = subject.load_groups([1, m_obj0], [2, m_obj1])
                    assert_equal [proxy0], obj0
                    assert_equal 42, proxy0.value
                    assert_equal [42], obj1
                end

                it "passes the unmarshalled objects to a block if one is given" do
                    m_obj0, m_obj1 = flexmock(proxy: 24), flexmock(proxy: 42)
                    subject.load_groups([1, m_obj0], [2, m_obj1]) do |m_obj0, m_obj1|
                        assert_equal [24], m_obj0
                        assert_equal [42], m_obj1
                    end
                end

                it "use IDs to load the objects from within the block" do
                    m_obj0, m_obj1 = flexmock(proxy: 24), flexmock(proxy: 42)
                    subject.load_groups([1, m_obj0], [2, m_obj1]) do
                        assert_equal 24, subject.local_object(m_obj0)
                        assert_equal 42, subject.local_object(m_obj1)
                    end
                end

                it "returns the block's return value" do
                    m_obj0, m_obj1 = flexmock(proxy: 24), flexmock(proxy: 42)
                    assert_equal 42, subject.load_groups([1, m_obj0], [2, m_obj1]) { 42 }
                end

                it "does not use IDs to dump the objects when it returned" do
                    m_obj0, m_obj1 = flexmock(proxy: 24), flexmock(proxy: 42)
                    subject.load_groups([1, m_obj0], [2, m_obj1]) {}
                    assert_equal 1, subject.local_object(1)
                end
            end
        end
    end
end

