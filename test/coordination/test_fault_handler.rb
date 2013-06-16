$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Coordination::Models::FaultHandler do
    include Roby::SelfTest

    attr_reader :m0, :m1, :m2, :t0, :t1, :t2, :handler
    before do
        @m0, @m1, @m2, @t0, @t1, @t2 = prepare_plan :add => 6, :model => Roby::Tasks::Simple
        m0.depends_on m1
        m1.depends_on t1
        t1.depends_on t2

        m0.depends_on t1
        m2.depends_on m1
        t0.depends_on t1

        fault_response_table = Roby::Coordination::FaultResponseTable.new_submodel
        @handler = Roby::Coordination::FaultHandler.new_submodel(fault_response_table)

        [m0, m1, m2, t0, t1, t2].each do |t|
            t.start!
        end
    end

    describe "#find_response_locations" do
        it "returns the running lowest-level missions that have the origin task as children" do
            [m0, m1, m2].each { |t| plan.add_mission(t) }
            handler.locate_on_missions
            result = handler.find_response_locations(t2)
            assert_equal [m0, m1].to_set, result
        end
        it "returns the running lowest-level actions that have the origin task as children" do
            m0.planned_by(Roby::Actions::Task.new)
            m1.planned_by(Roby::Actions::Task.new)
            m2.planned_by(Roby::Actions::Task.new)

            handler.locate_on_actions
            result = handler.find_response_locations(t2)
            assert_equal [m0, m1].to_set, result
        end
        it "returns the origin" do
            handler.locate_on_origin
            result = handler.find_response_locations(t1)
            assert_equal [t1].to_set, result
        end
    end
    describe "#activate" do
        before do
            [m0, m1, m2].each { |t| plan.add_mission(t) }
        end

        it "stops all the response locations and makes it so that stopping the response locations do not generate any exceptions" do
            flexmock(handler).should_receive(:find_response_locations).with(t2).and_return([m1].to_set)
            handler.activate(t2)
            assert m1.finished?
            assert m0.running?
            assert m2.running?
        end
        it "removes children so that the relevant ones are garbage-collected" do
            flexmock(handler).should_receive(:find_response_locations).with(t2).and_return([m0, m1].to_set)
            handler.activate(t2)
            plan.engine.garbage_collect_synchronous
            assert !t1.plan
            assert !t2.plan
            assert !t0.plan
            assert m1.plan
            assert m2.plan
            assert m0.plan
        end
    end
end


