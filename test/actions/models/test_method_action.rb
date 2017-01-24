require 'roby/test/self'

module Roby
    module Actions
        module Models
            describe MethodAction do
                describe "droby marshalling" do
                    attr_reader :interface_m, :action_m
                    before do
                        @interface_m = Actions::Interface.new_submodel(name: 'Actions')
                        @action_m = MethodAction.new(interface_m)
                        action_m.name = 'test'
                        interface_m.register_action 'test', action_m
                    end

                    it "marshals the interface and name" do
                        unmarshalled = droby_transfer(action_m)
                        assert(unmarshalled.action_interface_model < Actions::Interface)
                        assert_equal 'test', unmarshalled.name
                    end
                    it "unmarshals to an existing action on the loaded interface, if it exists" do
                        mapped_interface_m = droby_transfer(interface_m)

                        action_m = MethodAction.new(mapped_interface_m)
                        action_m.name = 'test'
                        mapped_interface_m.register_action 'test', action_m

                        unmarshalled = droby_transfer(action_m)
                        assert_equal mapped_interface_m, unmarshalled.action_interface_model
                    end
                end
            end
        end
    end
end

