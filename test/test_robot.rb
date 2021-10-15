# frozen_string_literal: true

require "roby/test/self"

describe Robot do
    attr_reader :interface_m

    before do
        @interface_m = Roby::Actions::Interface.new_submodel do
            describe "test_action"
            def test_action(**options)
                TestAction.new(**options)
            end
        end
        Roby.app.planners << interface_m
    end
    after do
        Roby.app.planners.delete(interface_m)
    end

    describe "#method_missing" do
        it "forwards exclamation-mark calls to Application#prepare_action" do
            task, planner = Robot.test_action!
            assert_kind_of interface_m::TestAction, task
            assert_equal interface_m.find_action_by_name(:test_action), planner.action_model
        end

        it "sets the job_id by default" do
            task, planner = Robot.test_action!
            refute_nil planner.job_id
        end

        it "allows to override the job_id to nil" do
            task, planner = Robot.test_action!(job_id: nil)
            assert_nil planner.job_id
        end

        it "forwards given options to the action" do
            task, planner = Robot.test_action!(offset: 10)
            assert_kind_of interface_m::TestAction, task
            assert_equal interface_m.find_action_by_name(:test_action), planner.action_model
        end
    end
end
