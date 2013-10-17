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

            def initialize(action_interface_model, root_task, arguments = Hash.new)
                super
                prepare

                root_task.execute do
                    step
                end
            end
        end
    end
end

