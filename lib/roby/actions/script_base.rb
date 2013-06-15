module Roby
    module Actions
        # Common logic for script-based coordination models
        module ScriptBase
            DeadInstruction = Models::Script::DeadInstruction

            attr_reader :current_instruction

            attr_reader :instructions

            def prepare
                @instructions = resolve_instructions
                @current_instruction = nil
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
                raise CodeError.new(e, root_task), e.message, e.backtrace
            end

            def finished?
                instructions.empty? && !@current_instruction
            end
        end
    end
end
