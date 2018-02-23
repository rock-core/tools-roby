require 'roby/test/self'

module Roby
    module Actions
        module Models
            describe MethodAction do
                attr_reader :interface_m, :action_m
                before do
                    @interface_m = Actions::Interface.new_submodel(name: 'Actions')
                    @action_m = MethodAction.new(interface_m)
                    action_m.name = 'test'
                    interface_m.register_action 'test', action_m
                end

                it "creates a placeholder task for services that can be replaced" do
                    srv_m = Roby::TaskService.new_submodel
                    @action_m.returns(srv_m)
                    task_m = Roby::Task.new_submodel
                    task_m.provides srv_m

                    plan.add(placeholder = @action_m.as_plan)
                    plan.replace_task(placeholder, task_m.new)
                end

                describe "droby marshalling" do
                    it "marshals the interface and name" do
                        unmarshalled = droby_transfer(action_m)
                        assert(unmarshalled.action_interface_model < Actions::Interface)
                        assert_equal 'test', unmarshalled.name
                    end

                    describe('when a remote action already exists with the same name') do
                        before do
                            @remote_interface_m = droby_transfer(interface_m)

                            @remote_action_m = MethodAction.new(@remote_interface_m)
                            @remote_action_m.name = 'test'
                            @remote_interface_m.register_action 'test', @remote_action_m
                        end

                        it "unmarshals to the existing action" do
                            unmarshalled = droby_transfer(action_m)
                            assert_same @remote_action_m, unmarshalled
                        end
                        it "registers the return type model even if the action already exists" do
                            droby_remote = droby_to_remote(@action_m)
                            flexmock(droby_remote_marshaller).should_receive(:local_object).
                                with(droby_remote.returned_type, any).once.
                                pass_thru
                            flexmock(droby_remote_marshaller).should_receive(:local_object).
                                pass_thru
                            droby_remote_marshaller.local_object(droby_remote)
                        end
                    end
                end
            end
        end
    end
end

