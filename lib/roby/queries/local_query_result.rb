# frozen_string_literal: true

module Roby
    module Queries
        class LocalQueryResult
            attr_reader :plan, :initial_set
            attr_accessor :result_set

            def initialize(plan, initial_set, result_set)
                @plan = plan
                @initial_set = initial_set
                @result_set = Set.new
                @result_set.compare_by_identity
                @result_set.merge(result_set)
            end

            def include?(obj)
                result_set.include?(obj)
            end

            def each(&block)
                result_set.each(&block)
            end
        end
    end
end
