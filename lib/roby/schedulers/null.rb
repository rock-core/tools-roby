# frozen_string_literal: true

require "roby/schedulers/reporting"

module Roby
    module Schedulers
        # A scheduler that does nothing, used by {ExecutionEngine} by default
        class Null < Reporting
            attr_predicate :enabled?, true

            attr_reader :plan

            def initialize(plan)
                super()

                @plan = plan
            end

            def initial_events
                []
            end
        end
    end
end
