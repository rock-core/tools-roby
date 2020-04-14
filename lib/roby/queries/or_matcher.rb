# frozen_string_literal: true

module Roby
    module Queries
        # Combines multiple task matching predicates through a OR boolean operator.
        # I.e. it will match if any of the underlying predicates match.
        class OrMatcher < MatcherBase
            # Create a new OrMatcher object combining the given predicates.
            def initialize(*ops)
                @ops = ops
            end

            # Add a new predicate to the combination
            def <<(op)
                @ops << op
                self
            end

            def merge(other)
                @ops.concat(other.instance_variable_get(:@ops))
                self
            end

            def ===(task)
                @ops.any? { |op| op === task }
            end

            # Enumerate the objects matching self in the plan
            def each_in_plan(plan)
                return enum_for(__method__, plan) unless block_given?

                seen = Set.new
                seen.compare_by_identity
                @ops.each do |op|
                    op.each_in_plan(plan) do |obj|
                        next unless seen.add?(obj)

                        yield(obj)
                    end
                end
            end

            # Version of {OrMatcher} specialized for {TaskMatcher}
            #
            # Do not create directly, use {TaskMatcher#|} instead
            class Tasks < OrMatcher
                def evaluate(plan)
                    @ops.map { |o| o.evaluate(plan) }
                        .inject(&:|)
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
