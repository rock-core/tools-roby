module Roby
    module Queries

    # Combines multiple task matching predicates through a OR boolean operator.
    # I.e. it will match if any of the underlying predicates match.
    class OrMatcher < MatcherBase
        # Create a new OrMatcher object combining the given predicates.
        def initialize(*ops)
            @ops = ops 
        end

        # Overload of TaskMatcher#filter
        def filter(task_set, task_index)
            result = Set.new
            for child in @ops
                result.merge child.filter(task_set, task_index)
            end
            result
        end

        # Add a new predicate to the combination
        def <<(op); @ops << op end

        def ===(task)
            @ops.any? { |op| op === task }
        end
    end

    end
end
