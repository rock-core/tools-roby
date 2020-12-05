# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Test
        describe Assertions do
            describe "test of captures in action state machines" do
                before do
                    @task_m = task_m = Roby::Task.new_submodel do
                        argument :id, default: 0
                        terminates
                    end

                    @interface = Actions::Interface.new_submodel do
                        describe("some_action")
                            .returns(task_m)
                            .optional_arg("id", "some identifier", 0)
                        define_method :some_action do |id: 0|
                            task_m.new(id: id)
                        end

                        describe("the state machine action")
                            .optional_arg("factor", "for the with_arg capture", 5)
                        action_state_machine "test_machine" do
                            start_state = state(some_action)
                            start(start_state)
                            value = capture(start_state.success_event) do |ev|
                                ev.context.first * 2
                            end
                            with_arg = capture(start_state.success_event) do |ev|
                                ev.context.first * factor
                            end
                            start_state.success_event.forward_to success_event
                        end
                    end
                end

                describe "validate_state_machine" do
                    it "handles an action object" do
                        task_m = @task_m
                        test = self
                        validate_state_machine @interface.test_machine do
                            test.assert_kind_of task_m, current_state_task
                            test.assert current_state_task.pending?
                        end
                    end

                    it "plans the machine's start state" do
                        task_m = @task_m
                        test = self
                        validate_state_machine @interface.new(plan).test_machine do
                            test.assert_kind_of task_m, current_state_task
                            test.assert current_state_task.pending?
                        end
                    end

                    describe "assert_transitions_to_state" do
                        before do
                            @interface.describe("the state machine action")
                            @interface.action_state_machine "with_transition" do
                                s0 = state(some_action(id: 1))
                                start(s0)
                                s1 = state(some_action(id: 2))

                                transition s0.success_event, s1
                                s1.success_event.forward_to success_event
                            end
                        end

                        it "yields the current state and returns the next state's task" do
                            test = self
                            validate_state_machine @interface.new(plan).with_transition do
                                assert_transitions_to_state "s1" do |task|
                                    test.assert_equal 1, task.id
                                    execute { task.start! }
                                    execute { task.success_event.emit }
                                end
                            end
                        end

                        it "forwards _event and _child calls to the current state" do
                            validate_state_machine @interface.new(plan).with_transition do
                                assert_equal 1, current_state_task.id
                                assert_transitions_to_state "s1" do
                                    execute { start_event.call }
                                    execute { success_event.emit }
                                end
                                assert_equal 2, current_state_task.id
                            end
                        end
                    end
                end

                describe "#find_state_machine_capture" do
                    it "returns the capture if it exists" do
                        plan.add_mission_task(task = @interface.new(plan).test_machine)
                        capture, state_machine = find_state_machine_capture(task, "value")
                        assert_kind_of Coordination::Models::Capture, capture
                        assert_same state_machine, task.each_coordination_object.first
                    end
                    it "returns nil if it does not exist" do
                        plan.add_mission_task(task = @interface.new(plan).test_machine)
                        assert_nil find_state_machine_capture(task, "does_not_exist")
                    end
                    it "handles a task without coordination objects" do
                        plan.add_mission_task(task = Roby::Task.new)
                        assert_nil find_state_machine_capture(task, "does_not_exist")
                    end
                end

                describe "#run_state_machine_capture" do
                    before do
                        @task = @interface.new(plan).test_machine
                    end
                    it "runs the capture with the provided context and returns its result" do
                        result = run_state_machine_capture(@task, "value", context: [42])
                        assert_equal 84, result
                    end
                    it "passes the state machine to the capture context" do
                        result = run_state_machine_capture(@task, "with_arg", context: [42])
                        assert_equal 210, result
                    end
                    it "accepts a non-array as context" do
                        plan.add_mission_task(@interface.new(plan).test_machine)
                        result = run_state_machine_capture(@task, "value", context: 42)
                        assert_equal 84, result
                    end
                    it "can pass a raw event object" do
                        event = flexmock(context: [42])
                        result = run_state_machine_capture(@task, "value", event: event)
                        assert_equal 84, result
                    end
                    it "raises if given both event and context" do
                        e = assert_raises(ArgumentError) do
                            run_state_machine_capture(
                                @task, "value",
                                event: Object.new, context: 42
                            )
                        end
                        assert_equal "cannot pass both context and event", e.message
                    end
                    it "raises if given both event and context" do
                        e = assert_raises(ArgumentError) do
                            run_state_machine_capture(
                                @task, "value",
                                event: Object.new, context: [42]
                            )
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
