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
            def filter(initial_set, _task_index)
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

            def negative_results(plan)
                @negative_results ||= plan.query_result_set(@op)
            end

            def reset
                @negative_results = nil
            end

            # Enumerate the objects matching self in the plan
            def each_in_plan(plan)
                return enum_for(__method__, plan) unless block_given?

                seen = Set.new
                seen.compare_by_identity
                negatives = negative_results(plan).to_set
                plan.tasks.each do |t|
                    yield(t) unless negatives.
                    plan.query_each(op_result) do |obj|
                        next unless seen.add?(obj)

                        yield(obj)
                    end
                end
            end
        end
    end
end
