# frozen_string_literal: true

require "roby/schedulers/reporting"

module Roby
    module Schedulers
        # Scheduler that handles temporal, scheduling, dependency and planning relations
        # in a global graph-based resolution
        #
        # As all schedulers, its only entry point is {#initial_events}. The rest must
        # be considered private API
        #
        # It bases scheduling decisions on temporal constraints and on the scheduling
        # constraint graph. It interprets some core Roby relations as schedule_as
        # constraints:
        #
        # - children of the depends_on relation should be scheduled as their parents
        # - children of the planned_by relation should be scheduled as their parents
        #
        # The main difference between the two is the handling of non-executable tasks.
        # In the case of the dependency relation, the child will not be schedulable if
        # the parent is non-executable. It is obviously not the case for the planned_by
        # relation
        #
        # The main idea of the algorithm is to resolve the "scheduling groups" and their
        # relationships, that is the set of tasks that have to be scheduled together
        # because they form a connected component in the schedule_as relation. These
        # groups then are organized in a graph where an edge represents that all tasks
        # of group have to wait for all the tasks of the other. We then reason only on
        # these groups
        #
        # The constraints is "relaxed" in the presence of temporal
        # constraints: if a child must be started before its parent, the scheduler
        # will start the child first, but only if the parent would be scheduled assuming
        # other temporal constraints are met. This allows to add cross-constraints on
        # scheduling and trust the scheduler to relax them when temporal constraints
        # need it
        #
        # It is a global resolution scheduler. That is, it will simultaneously start all
        # tasks in the graph that can be started at the same time. If a parent task needs
        # to be started first (the behaviour of Basic and Temporal), add an explicit
        # temporal relation via the {Task#should_start_after} helper
        class Global < Reporting
            class InternalError < RuntimeError; end

            attr_reader :plan

            attr_predicate :enabled?, true

            def initialize(plan = Roby.plan)
                super()

                @enabled = true
                @plan = plan
            end

            STATE_UNDECIDED = nil
            STATE_SCHEDULABLE = :schedulable
            STATE_NON_SCHEDULABLE = :non_schedulable
            STATE_PENDING_CONSTRAINTS = :pending_constraints

            # Starts all tasks that are eligible. See the documentation of the
            # Basic class for an in-depth description
            def initial_events(time: Time.now)
                compute_tasks_to_schedule(time: time)
                    .each(&:start!)
            end

            def compute_tasks_to_schedule(time: Time.now)
                candidates = @plan.find_tasks.pending.self_owned.to_a
                return [] if candidates.empty?

                scheduled_as = create_scheduled_as_graph(candidates)
                scheduling_groups = create_scheduling_group_graph(scheduled_as)

                propagate_scheduling_state(candidates, scheduling_groups, time)
                validate_scheduling_state_propagation(scheduling_groups)
                relax_scheduling_constraints(scheduling_groups)
                resolve_tasks_to_schedule(scheduling_groups)
            end

            # Return the set of tasks that can be started
            def resolve_tasks_to_schedule(scheduling_groups)
                scheduling_groups.each_vertex.each_with_object(Set.new) do |group, set|
                    next unless group.state == STATE_SCHEDULABLE
                    next unless group.non_executable_tasks.empty?

                    if group.held_by_temporal.empty?
                        set.merge(group.tasks)
                    else
                        group.held_by_temporal.each do |group|
                            set.merge(group.temporal_constraints.related_tasks)
                        end
                    end
                end
            end

            # Follow the scheduling constraints to add holding constraints to the groups
            # that are scheduled as the held group
            #
            # At the end of this call:
            # - all held_by_temporal and held_non_schedulable of a group are added to the
            #   groups that should be scheduled the same way.
            # - the 'state' reflects the worst-case
            #   (non_schedulable > scheduling > temporal)
            def propagate_scheduling_state(candidates, graph, time)
                queue = graph.each_vertex.find_all { |v| graph.leaf?(v) }

                # Do a BFS by hand, queueing vertices only when all scheduling parents
                # have been resolved
                until queue.empty?
                    group = queue.shift
                    resolve_scheduling_constraints(graph, group)
                    scheduling_state_resolve_can_schedule_and_execute_group(group)
                    scheduling_state_resolve_temporal_constraints(candidates, group, time)

                    group.state = group.resolve_state

                    queue.concat(propagate_scheduling_next_steps(graph, group))
                end
            end

            # Return the groups that can be added to the processing queue of
            # {#propagate_scheduling_state} main loop because of the finished processing
            # of the given group
            #
            # @param [Relations::BidirectionalDirectedAdjacencyGraph] the scheduling graph
            # @param [SchedulingGroup] group the group that was just processed
            # @return [Array<SchedulingGroup>]
            def propagate_scheduling_next_steps(graph, group)
                graph.each_in_neighbour(group).find_all do |child|
                    propagate_scheduling_ready?(graph, child)
                end
            end

            # Tests whether the given group can be processed by the
            # propagate_scheduling_state main loop
            #
            # @param [Relations::BidirectionalDirectedAdjacencyGraph] the scheduling graph
            # @param [SchedulingGroup] group the group that was just processed
            def propagate_scheduling_ready?(graph, group)
                graph.each_out_neighbour(group)
                     .all? { |parent| parent.state != STATE_UNDECIDED }
            end

            def scheduling_state_resolve_can_schedule_and_execute_group(group)
                group.can_schedule = group.tasks.all? { |t| task_can_schedule?(t) }
                group.tasks.each do |t|
                    group.non_executable_tasks << t unless task_can_execute?(t)
                end
            end

            def scheduling_state_resolve_temporal_constraints(candidates, group, time)
                group.temporal_constraints = resolve_temporal_constraints(group, time)
                return if group.temporal_constraints.ok?

                group.held_by_temporal << group
                group.external_temporal_constraints =
                    group_has_external_temporal_constraints?(candidates, group)
            end

            # Test whether some of the failed temporal constraints depend on tasks
            # that are beyond the reach of the scheduler
            def group_has_external_temporal_constraints?(candidates, group)
                group.temporal_constraints.related_tasks.any? do |task|
                    !candidates.include?(task)
                end
            end

            def validate_scheduling_state_propagation(graph)
                graph.each_vertex do |group|
                    if group.state == STATE_UNDECIDED
                        raise InternalError,
                              "group in STATE_UNDECIDED after propagation"
                    end
                end
            end

            # Look for recursive scheduling constraints - temporal or about non-executable
            # tasks - and check if we can resolve them by allowing some tasks to be
            # executed
            #
            # In practice, this looks for set of groups that we have to relax
            # together to allow for the scheduling of all of them (or almost)
            #
            # The 'almost' part has to do with temporal constraints and non-executable
            # tasks. What the relaxation is trying to find is the set of groups that,
            # if we were to allow for the execution of planning tasks and/or temporal
            # prerequisite (i.e. scheduling subsets), would be schedulable.
            def relax_scheduling_constraints(scheduling_groups)
                relaxation_graph, self_edges = relaxation_create_graph(scheduling_groups)

                scheduling_groups.each_vertex do |group|
                    next unless group.state == STATE_PENDING_CONSTRAINTS

                    related = relaxation_compute_related_groups(
                        scheduling_groups, relaxation_graph, self_edges, group
                    )
                    unless related
                        # In the negative, we can't infer anything about other
                        # groups ... need to re-process them
                        group.state = STATE_NON_SCHEDULABLE
                        next
                    end

                    relaxed = related.all? do |g|
                        g.state == STATE_SCHEDULABLE ||
                            g.state == STATE_PENDING_CONSTRAINTS
                    end
                    related.each { |g| g.state = STATE_SCHEDULABLE } if relaxed
                end
            end

            # Create a graph on which {#relax_scheduling_constraints} will work
            #
            # This graph represents the 'live' scheduling constraints, that is an edge
            # a->b means that `a` has a schedule_as constraint on `b` and `b` is
            # currently not directly schedulable. This is a transitive relation, that is
            # the out edges of a given group represent all the known constraints
            def relaxation_create_graph(scheduling_groups)
                relaxation_graph = Relations::BidirectionalDirectedAdjacencyGraph.new
                self_edges = Set.new
                scheduling_groups.each_vertex do |group|
                    next unless group.state == STATE_PENDING_CONSTRAINTS

                    relaxation_add_groups(
                        relaxation_graph, self_edges, group, group.held_by_temporal
                    )
                    relaxation_add_groups(
                        relaxation_graph, self_edges, group, group.held_non_executable
                    )
                end
                [relaxation_graph, self_edges]
            end

            # Helper for {#relaxation_create_graph}
            def relaxation_add_groups(relaxation_graph, self_edges, ref, groups)
                groups.each do |holding_group|
                    if ref == holding_group
                        self_edges << ref
                    else
                        relaxation_graph.add_edge(ref, holding_group)
                    end
                end
            end

            # Compute the set of groups that need to be resolved together to allow
            # for their (collective) scheduling
            def relaxation_compute_related_groups(
                scheduling_groups, relaxation_graph, self_edges, seed_group
            )
                queue = [seed_group]
                seen_holding_groups = Set.new
                related_groups = Set.new
                until queue.empty?
                    g = queue.shift
                    next unless related_groups.add?(g)

                    holding_groups =
                        relaxation_compute_holding_groups(g, relaxation_graph, self_edges)

                    valid = holding_groups.all? do |holding_g|
                        next(true) unless seen_holding_groups.add?(holding_g)

                        dependent_groups = relaxation_compute_dependent_groups(
                            scheduling_groups, holding_g
                        )
                        queue.concat(dependent_groups.to_a) if dependent_groups
                    end
                    return unless valid
                end

                related_groups
            end

            def relaxation_compute_holding_groups(group, relaxation_graph, self_edges)
                holding_groups = relaxation_graph.out_neighbours(group)
                holding_groups |= [group] if self_edges.include?(group)
                holding_groups
            end

            def relaxation_compute_dependent_groups(scheduling_groups, holding_group)
                dependent_groups = Set.new

                all_planned = relaxation_add_planning_tasks_to_dependent_groups(
                    dependent_groups, holding_group, scheduling_groups
                )
                return unless all_planned

                all_valid = relaxation_add_temporal_constraints_to_dependent_groups(
                    dependent_groups, holding_group, scheduling_groups
                )
                return unless all_valid

                dependent_groups
            end

            def relaxation_add_planning_tasks_to_dependent_groups(
                dependent_groups, holding_group, scheduling_groups
            )
                planned_by = @plan.task_relation_graph_for(TaskStructure::PlannedBy)
                holding_group.non_executable_tasks.all? do |planned_task|
                    planning_groups =
                        planned_by.each_out_neighbour(planned_task).map do |planning_task|
                            scheduling_groups
                                .find_planning_task_group(holding_group, planning_task)
                        end

                    planning_groups = planning_groups.compact
                    dependent_groups.merge(planning_groups) unless planning_groups.empty?
                end
            end

            def relaxation_add_temporal_constraints_to_dependent_groups(
                dependent_groups, holding_group, scheduling_groups
            )
                holding_group.temporal_constraints.related_tasks.all? do |task|
                    group = scheduling_groups.find_task_group(task)
                    # If nil, this is not a task we can schedule
                    dependent_groups << group if group
                end
            end

            # Compute the set of groups that this group (recursively) depends on
            #
            # This is the actual set that {#relax_scheduling_constraints} is trying to
            # solve
            def resolve_holding_groups(root_group)
                result = Set.new
                queue = [root_group]
                until queue.empty?
                    group = queue.shift
                    next unless result.add?(group)

                    queue.concat(
                        (group.held_by_temporal | group.held_non_executable).to_a
                    )
                end
                result
            end

            # Register the reasons why a group is held by scheduling constraints
            def resolve_scheduling_constraints(graph, group)
                graph.each_out_neighbour(group) do |scheduled_as_group|
                    group.held_by_temporal.merge(
                        scheduled_as_group.held_by_temporal
                    )
                    group.held_non_schedulable.merge(
                        scheduled_as_group.held_non_schedulable
                    )
                    group.held_non_executable.merge(
                        scheduled_as_group.held_non_executable
                    )
                end
            end

            # Register all temporal constraints failures within a group
            #
            # @return [TemporalConstraintResult]
            def resolve_temporal_constraints(group, time)
                result = TemporalConstraintResult.new(
                    failed_temporal: {}, failed_occurence: {}
                )

                group.each do |task|
                    result.add_from_task(task, time)
                end
                result
            end

            def resolve_task_temporal_constraints(result, task)
                start_event = task.start_event
                result.failed_temporal[task] =
                    start_event.each_failed_temporal_constraint(time).to_a
                result.failed_occurence[task] =
                    start_event
                    .each_failed_occurence_constraint(use_last_event: true).to_a
            end

            # @api private
            #
            # Graph that handles scheduling groups
            #
            # This graph is the main data structure of the global scheduler. Groups
            # are set of tasks that have to be scheduled together (they form a
            # transitive closure w.r.t. the schedule_as relation) and edges between
            # the groups represent the schedule_as relations between the groups.
            class SchedulingGroupsGraph < Relations::BidirectionalDirectedAdjacencyGraph
                NOT_MY_TASK = Object.new.freeze

                def initialize
                    super

                    @task_to_group = {}
                    @task_to_group.compare_by_identity
                end

                def find_task_group(task)
                    if (cached = @task_to_group[task])
                        return (cached unless cached == NOT_MY_TASK)
                    end

                    match = each_vertex.find { |g| g.include?(task) }
                    @task_to_group[task] = match || NOT_MY_TASK
                    match
                end

                # Find a task's group in the special case of a planning task that plans
                # a task from a group we know
                #
                # The method uses the fact that a.planned_by(b) implies b.schedule_as(a)
                def find_planning_task_group(group, planning_task)
                    if (cached = @task_to_group[planning_task])
                        return (cached unless cached == NOT_MY_TASK)
                    end

                    return group if group.include?(planning_task)

                    match = each_in_neighbour(group).find do |g|
                        g.include?(planning_task)
                    end
                    @task_to_group[planning_task] = match || NOT_MY_TASK
                    match
                end
            end

            # Create a graph where u->v indicates that `v` should be schedulable for `u`
            # to be schedulable (u.schedule_as(v))
            def create_scheduled_as_graph(candidates)
                graph = Relations::BidirectionalDirectedAdjacencyGraph.new
                candidates.each { |v| graph.add_vertex(v) }

                scheduling_graph_add_scheduling_constraints(graph)
                scheduling_graph_add_dependency(graph)
                scheduling_graph_add_planned_by(graph)

                graph.delete_vertex_if do |v|
                    !candidates.include?(v)
                end
                graph
            end

            def scheduling_graph_add_scheduling_constraints(graph)
                scheduled_as =
                    @plan.event_relation_graph_for(EventStructure::SchedulingConstraints)

                scheduled_as.each_edge do |u, v|
                    next unless u.respond_to?(:task) && v.respond_to?(:task)
                    next unless u.symbol == :start && v.symbol == :start

                    graph.add_edge(v.task, u.task)
                end
            end

            def scheduling_graph_add_dependency(graph)
                graph.merge(
                    @plan.task_relation_graph_for(TaskStructure::Dependency)
                         .reverse
                )
            end

            def scheduling_graph_add_planned_by(graph)
                graph.merge(
                    @plan.task_relation_graph_for(TaskStructure::PlannedBy)
                         .reverse
                )
            end

            # Create the condensed graph of the given scheduling graph, where vertices
            # are instances of SchedulingGroup
            #
            # In the scheduling graph, an edge a->b means that 'a' is scheduled_as 'b'
            def create_scheduling_group_graph(scheduled_as)
                condensed = scheduled_as.condensation_graph

                graph = SchedulingGroupsGraph.new
                set_id_to_group = {}
                set_id_to_group.compare_by_identity
                condensed.each_vertex do |u, _v|
                    group = SchedulingGroup.new(
                        tasks: u,
                        held_by_temporal: Set.new,
                        held_non_schedulable: Set.new,
                        held_non_executable: Set.new,
                        non_executable_tasks: Set.new
                    )
                    set_id_to_group[u] = group
                    graph.add_vertex(group)
                end

                condensed.each_edge do |u, v|
                    graph.add_edge(set_id_to_group[u], set_id_to_group[v])
                end

                graph
            end

            def task_can_execute?(task)
                unless task.executable?
                    report_pending_non_executable_task("#{task} is not executable", task)
                    return false
                end

                true
            end

            def task_can_schedule?(task) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
                start_event = task.start_event
                unless start_event.controlable?
                    report_holdoff "start event not controlable", task
                    return false
                end

                if (agent = task.execution_agent) && !agent.ready_event.emitted?
                    report_holdoff "task's execution agent %2 is not ready", task, agent
                    return false
                end

                unless start_event.root?(EventStructure::CausalLink)
                    report_holdoff "start event not root in the causal link relation",
                                   task
                    return false
                end

                task.each_relation do |r|
                    if r.respond_to?(:scheduling?) && !r.scheduling? && !task.root?(r)
                        report_holdoff "not root in %2, which forbids scheduling", task, r
                        return false
                    end
                end
                true
            end

            # Representation of a group of tasks that should be scheduled together or not
            # at all
            #
            # @!method tasks
            #   @return [Array<Task>] the list of tasks in the group
            #
            # @!method temporal_constraints
            #   @return [Array<Task>] a list of tasks from the group that are parents in
            #      a temporal constraint whose child is also in the group
            #
            # @!method state
            #   @return one of the STATE constants
            SchedulingGroup = Struct.new(
                :tasks, :temporal_constraints, :external_temporal_constraints,
                :can_schedule, :non_executable_tasks,
                :held_by_temporal, :held_non_schedulable, :held_non_executable,
                :state, keyword_init: true
            ) do
                def each(&block)
                    tasks.each(&block)
                end

                def scheduling_constraint_state
                    return STATE_NON_SCHEDULABLE unless held_non_schedulable.empty?

                    unless held_non_executable.empty? && held_by_temporal.empty?
                        return STATE_PENDING_CONSTRAINTS
                    end

                    nil
                end

                def resolve_state
                    if !can_schedule || external_temporal_constraints
                        held_non_schedulable << self
                        STATE_NON_SCHEDULABLE
                    elsif !non_executable_tasks.empty?
                        held_non_executable << self
                        STATE_PENDING_CONSTRAINTS
                    elsif (state = scheduling_constraint_state)
                        state
                    else
                        STATE_SCHEDULABLE
                    end
                end

                def hash
                    object_id
                end

                def ==(other)
                    equal?(other)
                end

                def eql?(other)
                    equal?(other)
                end
            end

            TemporalConstraintResult = Struct.new(
                :failed_temporal, :failed_occurence, keyword_init: true
            ) do
                def ok?
                    failed_temporal.empty? && failed_occurence.empty?
                end

                def add_from_task(task, time)
                    start_event = task.start_event
                    temporal = start_event.each_failed_temporal_constraint(time).to_a
                    failed_temporal[task] = temporal unless temporal.empty?

                    occurence =
                        start_event
                        .each_failed_occurence_constraint(use_last_event: true).to_a
                    failed_occurence[task] = occurence unless occurence.empty?
                end

                def related_tasks
                    from_temporal = failed_temporal.each_value.flat_map do |array|
                        array.map { |f| f.parent.task }
                    end
                    from_occurence = failed_occurence.each_value.flat_map do |array|
                        array.map { |f| f.parent.task }
                    end

                    (from_temporal + from_occurence).to_set
                end
            end

            RelaxState = Struct.new(
                :relaxed, :temporal, :non_executable, keyword_init: true
            )
        end
    end
end
