require 'roby/test/self'

module Roby
    module DRoby
        module V5
            describe DRobyModel do
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

                describe "provided_models_of" do
                    it "stops at the superclass" do
                        super_m   = Module.new
                        super_m.include Module.new
                        m = Module.new do
                            extend ModelDumper
                            include super_m
                        end

                        flexmock(m).should_receive(:supermodel).
                            and_return(super_m)

                        assert_equal [], DRobyModel.provided_models_of(m)

                    end

                    it "selects only the modules that are extended by ModelDumper" do
                        dumped_m  = Module.new do
                            extend ModelDumper
                        end
                        ignored_m = Module.new
                        m = Module.new do
                            extend ModelDumper
                            include dumped_m
                            include ignored_m
                            def self.supermodel; nil end
                        end
                        assert_equal [dumped_m], DRobyModel.provided_models_of(m)

                    end
                end

                describe "#update" do
                    attr_reader :provided_m, :local, :droby_model
                    before do
                        @provided_m = Module.new { extend Identifiable }
                        @droby_model = DRobyModel.new('', Hash.new, Class.new, [marshalled_m = flexmock])
                        marshalled_m.should_receive(:proxy).and_return(provided_m)
                        @local = Class.new { extend Identifiable }
                    end

                    it "applies the unmarshalled provided models" do
                        flexmock(local).should_receive(:provides).with(provided_m).once
                        droby_model.update(demarshaller, local)
                    end

                    it "does not apply the models already provided by the local object" do
                        local.include provided_m
                        flexmock(local).should_receive(:provides).never
                        droby_model.update(demarshaller, local)
                    end
                end
            end
        end
    end
end


