# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Actions
        describe Interface do
            it "updates method actions referred to by method actions "\
               "to the ones provided with use_library " do
                task_m = Roby::Task.new_submodel

                a0 = Roby::Actions::Interface.new_submodel
                a0.class_eval do
                    describe("a0").returns(task_m)
                    define_method(:act) { task_m.new }
                end

                b0 = Roby::Actions::Interface.new_submodel
                b0.use_library a0
                b0.class_eval do
                    describe("b0").returns(task_m)
                    define_method(:b_act) { return act; }
                end

                sub_task_m = task_m.new_submodel

                a1 = a0.new_submodel
                a1.class_eval do
                    describe("a1").returns(task_m)
                    define_method(:act) { sub_task_m.new }
                end

                b1 = b0.new_submodel
                b1.use_library a1
                assert_kind_of Models::MethodAction, b1.act.model
                assert_same a1, b1.act.model.action_interface_model

                assert_kind_of sub_task_m, b1.new(plan).b_act
            end

            it "updates actions referred to by method actions "\
               "to the ones provided with use_library " do
                state_machine_m = Roby::Task.new_submodel { terminates }
                task_m = Roby::Task.new_submodel(name: "RootTask")

                a0 = Interface.new_submodel
                a0.class_eval do
                    describe("a0").returns(task_m)
                    define_method(:a0_start_action) { task_m.new }

                    describe("state machine").returns(state_machine_m)
                    action_state_machine :act do
                        start state(a0_start_action)
                    end
                end

                b0 = Interface.new_submodel
                b0.use_library a0
                b0.class_eval do
                    describe("b0").returns(state_machine_m)
                    define_method(:b_act) { return act; }
                end

                sub_task_m = task_m.new_submodel(name: "ChildTask")

                a1 = a0.new_submodel
                a1.class_eval do
                    describe("a1").returns(sub_task_m)
                    define_method(:a1_start_action) { sub_task_m.new }

                    describe("state machine").returns(state_machine_m)
                    action_state_machine :act do
                        start state(a1_start_action)
                    end
                end

                b1 = b0.new_submodel
                b1.use_library a1

                assert_same a1, b1.act.model.action_interface_model
                validate_state_machine b1.b_act do
                    assert_kind_of sub_task_m, current_state_task
                end
            end
        end
    end
end
