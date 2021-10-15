# frozen_string_literal: true

module Roby
    module Queries
        # Negate a given task-matching predicate
        #
        # This matcher will match if the underlying predicate does not match.
        class NotMatcher < MatcherBase
            # Create a new TaskMatcher which matches if and only if +op+ does not
            def initialize(op)
                super()

                @op = op
            end

            # True if the task matches at least one of the underlying predicates
            def ===(task)
                !(@op === task)
            end

            # Version of {NotMatcher} specialized for {TaskMatcher}
            #
            # Do not create directly, use {TaskMatcher#negate} instead
            class Tasks < NotMatcher
                def evaluate(plan)
                    @op.evaluate(plan).negate
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
