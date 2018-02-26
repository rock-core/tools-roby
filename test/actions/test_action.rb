require 'roby/test/self'
require 'roby/tasks/simple'

module Roby
    module Actions
        describe Action do
            describe "#has_missing_required_arg?" do
                attr_reader :action_m
                before do
                    @action_m = Interface.new_submodel
                end
                it "returns true if a required argument is unset" do
                    action_m.describe('test_action').required_arg('arg')
                    action_m.class_eval { def test_action(*args); end }
                    assert action_m.test_action.
                        has_missing_required_arg?
                end
                it "returns true if a required argument is set using a delayed argument object" do
                    action_m.describe('test_action').required_arg('arg')
                    action_m.class_eval { def test_action(*args); end }
                    assert action_m.test_action(arg: flexmock(evaluate_delayed_argument: nil)).
                        has_missing_required_arg?
                end
                it "returns false if an optional argument is unset" do
                    action_m.describe('test_action').optional_arg('arg', '', 10)
                    action_m.class_eval { def test_action(*args); end }
                    refute action_m.test_action.
                        has_missing_required_arg?
                end
                it "returns true if an optional argument is set using a delayed argument object" do
                    action_m.describe('test_action').optional_arg('arg', '', 10)
                    action_m.class_eval { def test_action(*args); end }
                    assert action_m.test_action(arg: flexmock(evaluate_delayed_argument: nil)).
                        has_missing_required_arg?
                end
                it "returns false if there are no arguments" do
                    action_m.describe('test_action')
                    action_m.class_eval { def test_action(*args); end }
                    refute action_m.test_action.
                        has_missing_required_arg?
                end
                it" returns false if all required arguments are set" do
                    action_m.describe('test_action').required_arg('arg')
                    action_m.class_eval { def test_action(*args); end }
                    refute action_m.test_action(arg: 10).
                        has_missing_required_arg?
                end
                it" returns false if all required arguments are set and some optional arguments are set" do
                    action_m.describe('test_action').
                        required_arg('required_arg').
                        optional_arg('optional_arg').
                        optional_arg('unset_optional_arg')
                    action_m.class_eval { def test_action(*args); end }
                    refute action_m.test_action(required_arg: 10, optional_arg: 20).
                        has_missing_required_arg?
                end
            end
        end
    end
end

