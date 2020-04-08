# frozen_string_literal: true

module Roby
    module Queries
        class PlanQueryResult < LocalQueryResult
            def local_query_results
                [self]
            end

            def each_in_plan(plan, &block)
                if plan != self.plan
                    raise ArgumentError,
                          "attempting to enumerate results of a query ran "\
                          "in #{self.plan} from #{plan}"
                end

                result_set.each(&block)
            end

            def roots(in_relation)
                self.class.roots_of(self, in_relation)
            end

            def |(other)
                if other.plan != plan
                    raise ArgumentError,
                          "cannot merge results from #{other.plan} "\
                          "in results from #{plan}"
                elsif !other.initial_set.equal?(initial_set)
                    raise ArgumentError,
                          "cannot merge results with different initial sets"
                end

                result = dup
                result.result_set = result_set | other.result_set
                result
            end

            def &(other)
                if other.plan != plan
                    raise ArgumentError,
                          "cannot merge results from #{other.plan} "\
                          "in results from #{plan}"
                elsif !other.initial_set.equal?(initial_set)
                    raise ArgumentError,
                          "cannot merge results with different initial sets"
                end

                result = dup
                result.result_set = result_set & other.result_set
                result
            end

            def negate
                result = dup
                result.result_set = initial_set - result_set
                result
            end

            # Called by TaskMatcher#result_set and Query#result_set to get the set
            # of tasks matching +matcher+
            def self.from_plan(plan, matcher) # :nodoc:
                filtered = matcher.filter(
                    plan.tasks, plan.task_index, initial_is_complete: true
                )

                if matcher.indexed_query?
                    new(plan, plan.tasks, filtered)
                else
                    result = Set.new
                    result.compare_by_identity
                    filtered.each { |task| result << task if matcher === task }
                    new(plan, plan.tasks, result)
                end
            end

            def self.root_in_query?(result_set, task, graph)
                graph.depth_first_visit(task) do |v|
                    return false if v != task && result_set.include?(v)
                end
                true
            end

            def self.roots_of(from, in_relation)
                plan = from.plan
                result_set = from.result_set

                graph = plan.task_relation_graph_for(in_relation).reverse
                new_results = result_set.find_all do |task|
                    root_in_query?(result_set, task, graph)
                end
                new(plan, from.initial_set, new_results)
            end
        end
    end
end
