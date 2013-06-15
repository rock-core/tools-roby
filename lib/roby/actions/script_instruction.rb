module Roby
    module Actions
        class ScriptInstruction
            attr_predicate :disabled?, true

            def cancel
                self.disabled = true
            end
        end
    end
end

