# frozen_string_literal: true

module Roby
    module Queries
        # Object that allows to describe a task's event generator and match it
        # in the plan
        #
        # It uses a task matcher to match the underlying task
        class TaskEventGeneratorMatcher < PlanObjectMatcher
            # @return [#===] the required event name
            attr_reader :symbol
            # @return [TaskMatcher] the task matcher that describes this event's
            #   task
            attr_reader :task_matcher

            # @return [Boolean] if true, self will match the specified generator
            #   as well as any other generator that is forwarded to it. If false
            #   (the default) only the specified generator will match
            attr_predicate :generalized?

            def initialize(task_matcher = Roby::Task.match, symbol = Queries.any)
                symbol = symbol.to_s if symbol.respond_to?(:to_sym)
                @symbol = symbol
                @task_matcher = task_matcher
                @generalized = false
                super()
            end

            # Makes this matcher a generalized matcher
            # @see #generalized?
            # @return self
            def generalized
                @generalized = true
                self
            end

            # Adds a matching object for the event's name
            #
            # @param [Regexp,Symbol,String,#===] symbol an object that will
            #   allow to match the event's name
            # @return self
            def with_name(symbol)
                @symbol =
                    if symbol.respond_to?(:to_sym) then symbol.to_s
                    else
                        symbol
                    end
                self
            end

            def to_s
                "#{task_matcher}.#{symbol}"
            end

            alias plan_object_match ===

            # Tests whether the given task event generator matches self
            #
            # @param [TaskEventGenerator] object
            # @return [Boolean]
            def ===(object)
                return unless object.kind_of?(TaskEventGenerator)

                if match_not_generalized(object)
                    true
                elsif generalized? && object.plan
                    forwarding_graph = object.relation_graph_for(
                        EventStructure::Forwarding
                    )
                    forwarding_graph.depth_first_visit(object) do |generator|
                        return true if match_not_generalized(generator)
                    end
                    false
                end
            end

            def match_not_generalized(object)
                (symbol === object.symbol.to_s) &&
                    plan_object_match(object) &&
                    (task_matcher === object.task)
            end

            # Enumerate the objects matching self in the plan
            def each_in_plan(plan)
                if generalized?
                    raise ArgumentError,
                          "cannot resolve a generalized matcher in the plan"
                end

                return enum_for(__method__, plan) unless block_given?

                @task_matcher.each_in_plan(plan) do |task|
                    event = task.event(symbol)
                    yield(event) if self === event
                end
            end
        end
    end
end
