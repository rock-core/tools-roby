require 'roby/test/self'

module Roby
    module DRoby
        module V5
            describe Builtins do
                let :local_id do
                    1
                end
                let :marshaller_object_manager do
                    ObjectManager.new(local_id)
                end
                let :marshaller do
                    Marshal.new(marshaller_object_manager, remote_id)
                end
                let :remote_id do
                    2
                end
                let :demarshaller_object_manager do
                    ObjectManager.new(remote_id)
                end
                let :demarshaller do
                    Marshal.new(demarshaller_object_manager, local_id)
                end

                def transfer(obj)
                    ::Marshal.load(::Marshal.dump(marshaller.dump(obj))).
                        proxy(demarshaller)
                end

                describe Builtins::ClassDumper do
                    attr_reader :local_base_class, :remote_base_class, :parent, :child
                    before do
                        @local_base_class = Class.new do
                            extend Identifiable
                        end
                        def local_base_class.name; 'Base' end
                        @remote_base_class = Class.new do
                            def self.name; 'Base' end
                            extend Identifiable
                        end
                        marshaller_object_manager.register_model(
                            local_base_class,
                            remote_id => remote_base_class.droby_id)
                        demarshaller_object_manager.register_model(
                            remote_base_class)
                        @parent = Class.new(local_base_class)
                        def parent.name; 'Parent' end
                        @child = Class.new(parent)
                        def child.name; 'Child' end
                    end

                    it "marshals and demarshals a class, rebuilding hierarchy" do
                        local_base_class.extend Builtins::ClassDumper
                        demarshalled = transfer(child)
                        assert_kind_of Class, demarshalled
                        refute_same child, demarshalled
                        refute_same parent, demarshalled.superclass
                        assert_equal 'Child', demarshalled.name
                        assert_equal 'Parent', demarshalled.superclass.name
                        assert_equal remote_base_class, demarshalled.superclass.superclass
                    end

                    it "registers the proxied models and reuse them" do
                        local_base_class.extend Builtins::ClassDumper
                        droby_demarshalled = ::Marshal.load(::Marshal.dump(marshaller.dump(child)))
                        proxied = droby_demarshalled.proxy(demarshaller)
                        assert_same proxied, droby_demarshalled.proxy(demarshaller)
                    end

                    it "stops marshalling at the toplevel ClassDumper class in the ancestry" do
                        parent.extend Builtins::ClassDumper
                        marshalled = marshaller.dump(child)
                        assert_nil marshalled.superclass.superclass
                    end

                    it "raises NoLocalObject on demarshalling if the toplevel class cannot be resolved locally" do
                        parent.extend Builtins::ClassDumper
                        marshalled = marshaller.dump(child)
                        assert_raises(NoLocalObject) do
                            demarshaller.local_object(marshalled)
                        end
                    end
                end

                describe Builtins::ExceptionDumper do
                    before do
                        demarshaller.register_model(Exception)
                    end

                    let :exception do
                        ArgumentError.exception("Test")
                    end

                    it "uses the DRoby marshaller as the demarshalled exception" do
                        demarshalled = transfer(exception)
                        assert_equal Builtins::ExceptionDumper::DRoby, demarshalled.class
                    end

                    it "is kind-of the original exception class" do
                        demarshalled = transfer(exception)
                        assert demarshalled.kind_of?(ArgumentError)
                        assert_same ArgumentError, demarshalled.exception_class
                    end
                end

                describe Builtins::ArrayDumper do
                    it "marshals its elements with #dump" do
                        a = [1, 2, 3]
                        flexmock(marshaller) do |r|
                            r.should_receive(:dump).with(a).pass_thru
                            r.should_receive(:dump).with(1).and_return('A')
                            r.should_receive(:dump).with(2).and_return('B')
                            r.should_receive(:dump).with(3).and_return('C')
                        end
                        assert_equal %w{A B C}, marshaller.dump(a)
                    end

                    it "proxies its elements with #local_object" do
                        a = [1, 2, 3]
                        flexmock(marshaller) do |r|
                            r.should_receive(:local_object).with(a).pass_thru
                            r.should_receive(:local_object).with(1).and_return('A')
                            r.should_receive(:local_object).with(2).and_return('B')
                            r.should_receive(:local_object).with(3).and_return('C')
                        end
                        assert_equal %w{A B C}, marshaller.local_object(a)
                    end
                end

                describe Builtins::HashDumper do
                    it "marshals its elements with #dump" do
                        a = Hash[1, 2, 3, 4]
                        flexmock(marshaller) do |r|
                            r.should_receive(:dump).with(a).pass_thru
                            r.should_receive(:dump).with(1).and_return('A')
                            r.should_receive(:dump).with(2).and_return('B')
                            r.should_receive(:dump).with(3).and_return('C')
                            r.should_receive(:dump).with(4).and_return('D')
                        end
                        assert_equal Hash['A' => 'B', 'C' => 'D'], marshaller.dump(a)
                    end

                    it "proxies its elements with #local_object" do
                        a = Hash[1, 2, 3, 4]
                        flexmock(marshaller) do |r|
                            r.should_receive(:local_object).with(a).pass_thru
                            r.should_receive(:local_object).with(1).and_return('A')
                            r.should_receive(:local_object).with(2).and_return('B')
                            r.should_receive(:local_object).with(3).and_return('C')
                            r.should_receive(:local_object).with(4).and_return('D')
                        end
                        assert_equal Hash['A' => 'B', 'C' => 'D'], marshaller.local_object(a)
                    end
                end

                describe Builtins::SetDumper do
                    it "marshals its elements with #dump" do
                        a = Set[1, 2, 3]
                        flexmock(marshaller) do |r|
                            r.should_receive(:dump).with(a).pass_thru
                            r.should_receive(:dump).with(1).and_return('A')
                            r.should_receive(:dump).with(2).and_return('B')
                            r.should_receive(:dump).with(3).and_return('C')
                        end
                        assert_equal %w{A B C}.to_set, marshaller.dump(a)
                    end

                    it "proxies its elements with #local_object" do
                        a = Set[1, 2, 3]
                        flexmock(marshaller) do |r|
                            r.should_receive(:local_object).with(a).pass_thru
                            r.should_receive(:local_object).with(1).and_return('A')
                            r.should_receive(:local_object).with(2).and_return('B')
                            r.should_receive(:local_object).with(3).and_return('C')
                        end
                        assert_equal %w{A B C}.to_set, marshaller.local_object(a)
                    end
                end
            end
        end
    end
end

