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
                @ops.each do |child|
                    result.merge child.filter(task_set, task_index)
                end
                result
            end

            # Add a new predicate to the combination
            def <<(op)
                @ops << op
            end

            def ===(task)
                @ops.any? { |op| op === task }
            end

            def result_set(plan)
                @result_set ||= @ops.map { |op| plan.query_result_set(op) }
            end

            # Enumerate the objects matching self in the plan
            def each_in_plan(plan)
                return enum_for(__method__, plan) unless block_given?

                seen = Set.new
                seen.compare_by_identity
                result_set(plan).each do |op_result|
                    plan.query_each(op_result) do |obj|
                        next unless seen.add?(obj)

                        yield(obj)
                    end
                end
            end
        end
    end
end
