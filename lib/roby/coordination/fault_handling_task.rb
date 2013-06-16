module Roby
    module Coordination
        class FaultHandlingTask < Roby::Task
            terminates

            # @return [FaultHandler] the fault handler that this task represents
            attr_accessor :fault_handler
        end
    end
end


