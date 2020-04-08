# frozen_string_literal: true

module Roby
    module Coordination
        class ActionScript < Actions
            extend Models::ActionScript
            include Script

            # The list of instructions, instanciated from model.instructions
            # using {Base#instance_for}
            attr_reader :instructions

            # The current instruction
            attr_reader :current_instruction

            def initialize(root_task, arguments = {})
                super
                prepare

                root_task.execute do
                    step
                end
            end
        end
    end
end
