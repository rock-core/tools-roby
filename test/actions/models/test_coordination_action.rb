# frozen_string_literal: true

require "roby/test/self"
module Roby
    module Actions
        module Models
            describe CoordinationAction do
                describe "droby marshalling" do
                    attr_reader :interface_m, :action_m, :machine_m
                    before do
                        @interface_m = Actions::Interface.new_submodel(name: "Actions")
                        task_m = Roby::Task.new_submodel(name: "RootTask")
                        interface_m.describe "test"
                        @machine_m = interface_m.action_state_machine("test") do
                            state = state(task_m)
                            start(state)
                        end
                        @action_m = interface_m.find_action_by_name("test")
                    end

                    it "marshals the interface and name" do
                        unmarshalled = droby_transfer(action_m)
                        assert(unmarshalled.action_interface_model < Actions::Interface)
                        assert_equal "test", unmarshalled.name
                    end

                    it "unmarshals to an existing action on the loaded interface, if it exists" do
                        mapped_interface_m = droby_transfer(interface_m)

                        action_m = MethodAction.new(mapped_interface_m)
                        action_m.name = "test"
                        mapped_interface_m.register_action "test", action_m

                        unmarshalled = droby_transfer(action_m)
                        assert_equal mapped_interface_m, unmarshalled.action_interface_model
                    end

                    it "creates a null Coordination::Actions object with the expected root" do
                        unmarshalled = droby_transfer(action_m)
                        assert(unmarshalled.coordination_model < Coordination::Actions)
                        assert_equal unmarshalled.returned_type,
                                     unmarshalled.coordination_model.task_model
                    end
                end
            end
        end
    end
end
