# frozen_string_literal: true

module Roby
    module Queries
        # Binding of a {TaskMatcher} with a particular plan
        #
        # This is used as return value for {plan.find_tasks}. The `.each_in_plan`
        # interface should be preferred instead:
        #
        # @example
        #   SomeTaskModel.match.with_arguments(some: arg).executable.mission
        #                .each_in_plan(plan)
        class Query < TaskMatcher
            # The plan this query acts on
            attr_reader :plan

            # Create a query object on the given plan
            def initialize(plan = nil)
                @plan = plan
                super()
            end

            def query
                self
            end

            # Changes the plan this query works on. This calls #reset (obviously)
            def plan=(new_plan)
                reset
                @plan = new_plan
            end

            # Reinitializes the cached query result.
            #
            # Queries cache their result, i.e. #each will always return the same
            # task set. #reset makes sure that the next call to #each will return
            # the same value.
            def reset
                @result_set = nil
                self
            end

            def result_set(plan)
                @result_set ||= evaluate(plan)
            end

            def roots(in_relation)
                @result_set = result_set(plan).roots(in_relation)
                self
            end

            # Iterates on all the tasks in the given plan which match the query
            #
            # This set is cached, i.e. #each will yield the same task set until
            # #reset is called.
            def each(&block)
                result_set(plan).each_in_plan(plan, &block)
            end
            include ::Enumerable
        end
    end
end
