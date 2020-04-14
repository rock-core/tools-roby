# frozen_string_literal: true

module Roby
    module Queries
        # This matcher combines multiple task matching predicates through a AND boolean
        # operator. I.e. it will match if none of the underlying predicates match.
        class AndMatcher < MatcherBase
            # Create a new AndMatcher object combining the given predicates.
            def initialize(*ops)
                @ops = ops
            end

            # Add a new predicate to the combination
            def <<(op)
                @ops << op
                self
            end

            # True if the task matches at least one of the underlying predicates
            def ===(task)
                @ops.all? { |op| op === task }
            end

            # Version of {AndMatcher} specialized for {TaskMatcher}
            #
            # Do not create directly, use {TaskMatcher#&} instead
            class Tasks < AndMatcher
                def evaluate(plan)
                    @ops.map { |o| o.evaluate(plan) }
                        .inject(&:&)
                end

                # Enumerate the objects matching self in the plan
                def each_in_plan(plan, &block)
                    return enum_for(__method__, plan) unless block_given?

                    evaluate(plan).each_in_plan(plan, &block)
                end
            end
        end
    end
end
