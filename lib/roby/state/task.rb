module Roby
    class Task
        def self.state
            if !@state
                if superclass.respond_to?(:state)
                    supermodel = superclass.state
                end
                @state = StateModel.new(supermodel)
            end
            @state
        end

        def state
            if @state
                return @state
            end
            @state = StateSpace.new(self.model.state)
        end

        def resolve_state_sources
            model.state.resolve_data_sources(self, state)
        end
    end
end

