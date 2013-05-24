module Roby
    module Queries
        class MatcherBase
            # Returns true if calling #filter with a task set and a relevant
            # index will return the exact query result or not
            def indexed_query?; false end

            # Enumerates all tasks of +plan+ which match this TaskMatcher object
            #
            # It is O(N). You should prefer use Query which uses the plan's task
            # indexes, thus leading to O(1) in simple cases.
            def each(plan)
                return enum_for(:each, plan) if !block_given?
                plan.each_task do |t|
                    yield(t) if self === t
                end
                self
            end

            # Negates this predicate
            #
            # The returned task matcher will yield tasks that are *not* matched by
            # +self+
            def negate; NotMatcher.new(self) end
            # AND-combination of two predicates 
            #
            # The returned task matcher will yield tasks that are matched by both
            # predicates.
            def &(other); AndMatcher.new(self, other) end
            # OR-combination of two predicates 
            #
            # The returned task matcher will yield tasks that match either one
            # predicate or the other.
            def |(other); OrMatcher.new(self, other) end
        end
    end
end
