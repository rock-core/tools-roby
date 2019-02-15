require 'roby/test/self'

module Roby
    module Test
        describe Assertions do
            describe "test of captures in action state machines" do
                before do
                    @interface = Actions::Interface.new_submodel do
                        describe 'some_action'
                        def some_action
                            SomeAction.new
                        end

                        describe 'the state machine action'
                        action_state_machine 'state_machine' do
                            start_state = state(some_action)
                            start(start_state)
                            value = capture(start_state.success_event) do |ev|
                                ev.context.first * 2
                            end
                            start_state.success_event.forward_to success_event
                        end
                    end
                end

                describe "#find_state_machine_capture" do
                    it "returns the capture if it exists" do
                        plan.add_mission_task(task = @interface.new(plan).state_machine)
                        assert_kind_of Coordination::Models::Capture,
                            find_state_machine_capture(task, 'value')
                    end
                    it "returns nil if it does not exist" do
                        plan.add_mission_task(task = @interface.new(plan).state_machine)
                        assert_nil find_state_machine_capture(task, 'does_not_exist')
                    end
                    it "handles a task without coordination objects" do
                        plan.add_mission_task(task = Roby::Task.new)
                        assert_nil find_state_machine_capture(task, 'does_not_exist')
                    end
                end

                describe "#run_state_machine_capture" do
                    before do
                        @task = @interface.new(plan).state_machine
                    end
                    it "runs the capture with the provided context and returns its result" do
                        result = run_state_machine_capture(@task, 'value', context: [42])
                        assert_equal 84, result
                    end
                    it "accepts a non-array as context" do
                        plan.add_mission_task(task = @interface.new(plan).state_machine)
                        result = run_state_machine_capture(@task, 'value', context: 42)
                        assert_equal 84, result
                    end
                    it "can pass a raw event object" do
                        event = flexmock(context: [42])
                        result = run_state_machine_capture(@task, 'value', event: event)
                        assert_equal 84, result
                    end
                    it "raises if given both event and context" do
                        e = assert_raises(ArgumentError) do
                            run_state_machine_capture(@task, "value",
                                event: Object.new, context: 42)
                        end
                        assert_equal "cannot pass both context and event", e.message
                    end
                    it "raises if given both event and context" do
                        e = assert_raises(ArgumentError) do
                            run_state_machine_capture(@task, "value",
                                event: Object.new, context: [42])
                        end
                        assert_equal "cannot pass both context and event", e.message
                    end
                    it "raises if the capture does not exist" do
                        e = assert_raises(ArgumentError) do
                            run_state_machine_capture(@task, "does_not_exist")
                        end
                        assert_equal "no capture named 'does_not_exist' in any state "\
                            "machine associated with #{@task}", e.message
                    end
                end
            end
        end
    end
end
