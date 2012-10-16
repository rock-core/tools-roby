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
            @state ||= StateSpace.new(self.model.state)
        end

        def resolve_state_sources
            model.state.resolve_data_sources(self, state)
        end

        def self.goal
            if !@goal
                if superclass.respond_to?(:goal)
                    supermodel = superclass.goal
                end
                @goal = GoalModel.new(self.state, supermodel)
            end
            @goal
        end

        def goal
            @goal ||= GoalSpace.new(self.model.goal)
        end
    end
end

