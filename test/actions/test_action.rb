# frozen_string_literal: true

require "roby/test/self"
require "roby/tasks/simple"

module Roby
    module Actions
        describe Action do
            describe "#with_arguments" do
                before do
                    @interface_m = Interface.new_submodel
                end

                it "does not modify an original action after a copy" do
                    @interface_m.describe("test_action")
                                .required_arg("t", "")
                    @interface_m.class_eval { def test_action(*args); end }

                    action1 = @interface_m.test_action(t: 10)
                    action2 = action1.dup.with_arguments(t: 20)
                    assert_equal 10, action1.arguments[:t]
                    assert_equal 20, action2.arguments[:t]
                end
            end

            describe "#missing_required_arguments" do
                attr_reader :interface_m

                before do
                    @interface_m = Interface.new_submodel
                end
                it "returns required arguments that are not set" do
                    action_m = interface_m.describe("test_action").required_arg("arg")
                    interface_m.class_eval { def test_action(*args); end }
                    assert_equal(
                        [action_m.find_arg("arg")],
                        interface_m.test_action.missing_required_arguments
                    )
                end
                it "returns required arguments set using a delayed argument object" do
                    action_m = interface_m.describe("test_action").required_arg("arg")
                    interface_m.class_eval { def test_action(*args); end }
                    assert_equal(
                        [action_m.find_arg("arg")],
                        interface_m.test_action(
                            arg: flexmock(evaluate_delayed_argument: nil)
                        ).missing_required_arguments
                    )
                end
                it "does not return unset optional arguments" do
                    interface_m.describe("test_action").optional_arg("arg", "", 10)
                    interface_m.class_eval { def test_action(*args); end }
                    assert_equal [], interface_m.test_action.missing_required_arguments
                end
                it "returns optional arguments set using a delayed argument object" do
                    action_m = interface_m.describe("test_action")
                                          .optional_arg("arg", "", 10)
                    interface_m.class_eval { def test_action(*args); end }
                    assert_equal(
                        [action_m.find_arg("arg")],
                        interface_m.test_action(
                            arg: flexmock(evaluate_delayed_argument: nil)
                        ).missing_required_arguments
                    )
                end
                it "returns an empty array if there are no arguments" do
                    interface_m.describe("test_action")
                    interface_m.class_eval { def test_action(*args); end }
                    assert_equal [], interface_m.test_action.missing_required_arguments
                end
                it "returns an empty array if all required arguments are set" do
                    interface_m.describe("test_action").required_arg("arg")
                    interface_m.class_eval { def test_action(*args); end }
                    assert_equal [], interface_m.test_action(arg: 10)
                                                .missing_required_arguments
                end
                it "returns an empty array if all required arguments are set " \
                   "and some optional arguments are set" do
                    interface_m.describe("test_action")
                               .required_arg("required_arg")
                               .optional_arg("optional_arg")
                               .optional_arg("unset_optional_arg")
                    interface_m.class_eval { def test_action(*args); end }
                    assert_equal [], interface_m
                        .test_action(required_arg: 10, optional_arg: 20)
                        .missing_required_arguments
                end
            end
            describe "#has_missing_required_arg?" do
                before do
                    @interface_m = Interface.new_submodel
                    @interface_m.describe("test_action")
                    @interface_m.class_eval { def test_action(*args); end }
                end
                it "returns true if there are missing required arguments" do
                    action = flexmock(@interface_m.test_action)
                    action.should_receive(missing_required_arguments: [flexmock])
                    assert action.has_missing_required_arg?
                end
                it "returns false if there are no missing required arguments" do
                    action = flexmock(@interface_m.test_action)
                    action.should_receive(missing_required_arguments: [])
                    refute action.has_missing_required_arg?
                end
            end
            describe "#with_example_arguments" do
                before do
                    @interface_m = Interface.new_submodel
                end

                it "leaves required arguments that are set" do
                    @interface_m.describe("test_action")
                                .required_arg("t", "", example: 20)
                    @interface_m.class_eval { def test_action(*args); end }
                    action = @interface_m.test_action(t: 10)
                    action.with_example_arguments
                    assert_equal 10, action.arguments[:t]
                end
                it "fills unset required arguments with their example" do
                    @interface_m.describe("test_action")
                                .required_arg("t", "", example: 20)
                    @interface_m.class_eval { def test_action(*args); end }
                    action = @interface_m.test_action
                    action.with_example_arguments
                    assert_equal 20, action.arguments[:t]
                end
                it "does not change unset required arguments " \
                   "if they do not have an example" do
                    @interface_m.describe("test_action")
                                .required_arg("t", "")
                    @interface_m.class_eval { def test_action(*args); end }
                    action = @interface_m.test_action
                    action.with_example_arguments
                    refute action.arguments.key?(:t)
                end
                it "does not modify an original action after a copy" do
                    @interface_m.describe("test_action")
                                .required_arg("t", "", example: 20)
                    @interface_m.class_eval { def test_action(*args); end }
                    action1 = @interface_m.test_action
                    action2 = action1.dup.with_example_arguments
                    refute action1.arguments.key?(:t)
                    assert_equal 20, action2.arguments[:t]
                end
            end
        end
    end
end
