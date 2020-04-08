# frozen_string_literal: true

module Roby
    module Coordination
        # Representation of a fault response from a {FaultResponseTable}
        class FaultHandlingTask < Roby::Task
            terminates

            # @return [FaultHandler] the fault handler that this task represents
            attr_accessor :fault_handler
        end
    end
end
