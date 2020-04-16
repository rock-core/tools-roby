# frozen_string_literal: true

module Roby
    class Task
        def self.state
            unless @state
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
            unless @goal
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

        def resolve_goals
            unless fully_instanciated?
                raise ArgumentError, "cannot resolve goals on a task that is not fully instanciated"
            end

            self.model.goal.resolve_goals(self, self.goal)
        end
    end
end
