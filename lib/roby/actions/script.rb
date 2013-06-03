module Roby
    module Actions
        class Script < ActionCoordination
            extend Models::Script

            DeadInstruction = Models::Script::DeadInstruction


            # The list of instructions, instanciated from model.instructions
            # using {ActionCoordination#instance_for}
            attr_reader :instructions

            # The current instruction
            attr_reader :current_instruction

            def initialize(action_interface_model, root_task, arguments = Hash.new)
                super
                @instructions = resolve_instructions
                @current_instruction = nil

                root_task.execute do
                    step
                end
            end

            def resolve_instructions
                model.instructions.map do |ins|
                    ins.new(self)
                end
            end

            def dependency_options_for(toplevel, task, roles)
                options = super
                if current_instruction.respond_to?(:task) && current_instruction.task == task
                    options = options.merge(current_instruction.dependency_options)
                end
                options
            end

            def step
                while @current_instruction = instructions.shift
                    if !current_instruction.execute(self)
                        break
                    end
                end
            rescue LocalizedError => e
                raise e
            rescue Exception => e
                raise CodeError.new(e, root_task)
            end

            def finished?
                instructions.empty? && !@current_instruction
            end
        end
    end
end

