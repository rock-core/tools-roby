# frozen_string_literal: true

module Roby
    module Queries
        class TransactionQueryResult
            def initialize(stack = [])
                @stack = stack
            end

            def local_query_results
                @stack
            end

            def push(query_result)
                @stack.push(query_result)
            end

            def each_in_plan(plan, &block)
                if plan != @stack.last.plan
                    raise ArgumentError,
                          "attempting to enumerate results of a query ran "\
                          "in #{@stack.first.plan} from #{plan}"
                end

                stack = @stack.dup
                stack.pop.each(&block)
                plan_stack = [plan]

                until stack.empty?
                    local_results = stack.pop
                    local_results.each do |local_obj|
                        wrapped_obj = plan_stack.inject(local_obj) do |obj, p|
                            p.wrap(obj)
                        end
                        yield(wrapped_obj)
                    end
                end
            end

            def roots(in_relation)
                self.class.roots_of(self, in_relation)
            end

            def self.from_transaction(transaction, matcher) # :nodoc:
                if matcher.scope == :global
                    up_results =
                        transaction
                        .plan.query_result_set(matcher)
                        .local_query_results
                    # remove tasks from the LAST plan that are proxied in self
                    # This is done recursively (i.e. already done for all the
                    # other levels)
                    plan_results = up_results.pop

                    final_result_set = Set.new
                    final_result_set.compare_by_identity
                    plan_results.each do |task|
                        unless transaction.has_proxy_for_task?(task)
                            final_result_set << task
                        end
                    end
                    plan_results.result_set = final_result_set
                    up_results.push plan_results
                else
                    up_results = []
                end

                new(up_results +
                    PlanQueryResult.from_plan(transaction, matcher).local_query_results)
            end

            class ReachabilityVisitor < RGL::DFSVisitor
                def initialize(graph, up_plan, up_seeds, this_set, down_plan, down_seeds)
                    super(graph)
                    @up_plan = up_plan
                    @up_seeds = up_seeds
                    @this_set = this_set
                    @down_plan = down_plan
                    @down_seeds = down_seeds
                end

                def handle_start_vertex(v)
                    @start_vertex = v
                end

                def follow_edge?(u, v)
                    !@down_plan || !(
                        @down_plan.find_local_object_for_task(u) &&
                        @down_plan.find_local_object_for_task(v)
                    )
                end

                def handle_examine_vertex(v)
                    if (@start_vertex != v) && @this_set.include?(v)
                        throw :reachable, true
                    elsif (proxy = @down_plan&.find_local_object_for_task(v))
                        @down_seeds << proxy
                    elsif v.transaction_proxy?
                        @up_seeds << v.__getobj__
                    end
                end
            end

            # @api private
            #
            # Tests whether a set of tasks can be reached from a set of seeds 'as if'
            # the transaction stack was applied
            #
            # Within 'stack', level N-1 is 'up', that is the plan of the
            # transaction at level N, and level N+1 is 'down', that is a transaction
            # built on top of level N.
            #
            # @param [Array<QueryRootsStackLevel>] stack
            def self.reachable_on_applied_transactions?(stack)
                visitors =
                    [QueryRootsStackLevel.null, *stack, QueryRootsStackLevel.null]
                    .each_cons(3).map do |up, this, down|
                        visitor = ReachabilityVisitor.new(
                            this.graph,
                            up.plan, up.seeds,
                            this.result_set,
                            down.plan, down.seeds
                        )
                        if (start = this.seeds.first)
                            visitor.handle_start_vertex(start)
                        end
                        [this, visitor]
                    end

                catch(:reachable) do
                    loop do
                        all_empty = true
                        visitors.each do |stack_level, visitor|
                            seeds = stack_level.seeds
                            until seeds.empty?
                                all_empty = false
                                seed = seeds.shift
                                unless visitor.finished_vertex?(seed)
                                    stack_level.graph.depth_first_visit(
                                        seed, visitor
                                    ) {}
                                end
                            end
                        end
                        break if all_empty
                    end
                    return false
                end
                true
            end

            QueryRootsStackLevel = Struct.new :local_results, :graph, :seeds do
                def plan
                    local_results.plan
                end

                def result_set
                    local_results.result_set
                end

                def self.null
                    QueryRootsStackLevel.new(
                        PlanQueryResult.new(nil, [], []), nil, []
                    )
                end
            end

            # @api private
            #
            # Given the result set of +query+, returns the subset of tasks which
            # have no parent in +query+
            #
            # This is never called directly, but is used by the Query API
            def self.roots_of(from, in_relation) # :nodoc:
                stack = from.local_query_results.map do |local_results|
                    local_plan = local_results.plan
                    local_graph = local_plan.task_relation_graph_for(in_relation)
                                            .reverse
                    QueryRootsStackLevel.new(local_results, local_graph, [])
                end

                roots_results = stack.map do |stack_level|
                    set = stack_level.local_results.result_set
                    roots = set.find_all do |task|
                        stack_level.seeds[0] = task
                        !reachable_on_applied_transactions?(stack)
                    end

                    new_results = stack_level.local_results.dup
                    new_results.result_set = roots
                    new_results
                end

                new(roots_results)
            end
        end
    end
end
