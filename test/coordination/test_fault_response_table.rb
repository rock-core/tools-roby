$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Coordination::FaultResponseTable do
    include Roby::SelfTest

    it "is triggered whenever an exception reaches toplevel" do
        fault_handler = nil
        fault_table = Roby::Coordination::FaultResponseTable.new_submodel do
            fault_handler = on_fault with_origin(Roby::Task.stop_event) do
                locate_on_origin
            end
        end
        plan.use_fault_response_table fault_table
        begin
            mission, child = prepare_plan :missions => 1, :add => 1,
                :model => Roby::Tasks::Simple
            mission.depends_on child, :role => 'name'
            mission.start!
            child.start!
            child.stop!

            repairs = child.find_all_matching_repair_tasks(child.failed_event.last)
            assert_equal 1, repairs.size
            repair_task = repairs.first
            process_events
            assert repair_task.running?
            assert_kind_of Roby::Coordination::FaultHandlingTask, repair_task
            assert_equal fault_handler, repair_task.fault_handler

        ensure
            plan.remove_fault_response_table fault_table
        end
    end

    it "can be attached to a specific task instance" do
        fault_table_m = Roby::Coordination::FaultResponseTable.new_submodel do
            argument :arg
        end
        task = Roby::Tasks::Simple.new
        task.use_fault_response_table fault_table_m, :arg => 20
        plan.add(task)
        task.start!
        assert_equal 1, plan.active_fault_response_tables.size
        table = plan.active_fault_response_tables.first
        assert_kind_of fault_table_m, table
        assert_equal Hash[:arg => 20], table.arguments
        task.stop!
        assert plan.active_fault_response_tables.empty?
    end

    describe "adding fault tables in transactions" do
        it "can be added in a transaction" do
            fault_table_m = Roby::Coordination::FaultResponseTable.new_submodel
            fault_table_m.argument :arg
            flexmock(plan).should_receive(:use_fault_response_table).with(fault_table_m, :arg => 10).once
            plan.in_transaction do |trsc|
                trsc.use_fault_response_table fault_table_m, :arg => 10
                trsc.commit_transaction
            end
        end
        it "is not added if the transaction is discarded" do
            fault_table_m = Roby::Coordination::FaultResponseTable.new_submodel
            fault_table_m.argument :arg
            flexmock(plan).should_receive(:use_fault_response_table).never
            plan.in_transaction do |trsc|
                trsc.use_fault_response_table fault_table_m, :arg => 10
                trsc.discard_transaction
            end
        end
    end
end


