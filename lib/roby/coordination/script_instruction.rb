module Roby
    module Coordination
        class ScriptInstruction
            attr_predicate :disabled?, true

            def cancel
                self.disabled = true
            end
        end
    end
end

