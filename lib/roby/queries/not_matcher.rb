module Roby
    module Queries

    # Negate a given task-matching predicate
    #
    # This matcher will match if the underlying predicate does not match.
    class NotMatcher < MatcherBase
        # Create a new TaskMatcher which matches if and only if +op+ does not
        def initialize(op)
            @op = op
        end

        # Filters as much as non-matching tasks as possible out of +task_set+,
        # based on the information in +task_index+
        def filter(initial_set, task_index)
            # WARNING: the value returned by filter is a SUPERSET of the
            # possible values for the query. Therefore, the result of
            # NegateTaskMatcher#filter is NOT
            #
            #   initial_set - @op.filter(...)
            initial_set
        end

        # True if the task matches at least one of the underlying predicates
        def ===(task)
            !(@op === task)
        end
    end
    end
end
