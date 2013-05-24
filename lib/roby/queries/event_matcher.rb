module Roby
    module Queries
        # Object that allows to describe an event generator and match it in the
        # plan
        #
        # It uses a task matcher to match the underlying task
        class EventGeneratorMatcher
            attr_reader :task_matcher
            def initialize(task_matcher)

        end
    end
end

