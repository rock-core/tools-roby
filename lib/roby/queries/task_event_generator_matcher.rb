module Roby
    module Queries
        # Object that allows to describe a task's event generator and match it
        # in the plan
        #
        # It uses a task matcher to match the underlying task
        class TaskEventGeneratorMatcher < PlanObjectMatcher
            # @return [#===] the required event name
            attr_reader :symbol
            # @return [TaskMatcher] the task matcher that describes this event's
            #   task
            attr_reader :task_matcher

            def initialize(task_matcher = Roby::Task.match, symbol = Queries.any)
                @symbol = symbol
                @task_matcher = task_matcher
                super()
            end

            # Adds a matching object for the event's name
            #
            # @param [Regexp,Symbol,String,#===] symbol an object that will
            #   allow to match the event's name
            # @return self
            def with_name(symbol)
                @symbol =
                    if symbol.respond_to?(:to_sym) then symbol.to_s
                    else symbol
                    end
                self
            end

            # @raise [NotImplementedError] Cannot yet do plan queries on task
            #   event generators
            def filter(initial_set, index)
                raise NotImplementedError
            end

            # Tests whether the given task event generator matches self
            #
            # @param [TaskEventGenerator] object
            # @return [Boolean]
            def ===(object)
                if !(symbol === object.symbol.to_s)
                    return false
                end
                return super && (task_matcher === object.task)
            end
        end
    end
end

