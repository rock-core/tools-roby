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

            failure_event = child.failed_event.last
            repairs = plan.repairs_for(failure_event)
            repair_task = repairs[failure_event]
            assert_kind_of Roby::Coordination::FaultHandlingTask, repair_task
            assert_equal fault_handler, repair_task.fault_handler

        ensure
            plan.remove_fault_response_table fault_table
        end
    end

    it "is used to handle the fault if a matching handler exists" do
    end
end


