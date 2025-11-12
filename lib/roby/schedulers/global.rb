# frozen_string_literal: true

require "roby/schedulers/reporting"

module Roby
    module Schedulers
        # The global scheduler is an evolution of the temporal one. Based on the same
        # information, but attempting to perform a global resolution
        #
        # As all schedulers, its only entry point is {#initial_events}. The rest must
        # be considered private API
        #
        # It bases scheduling decisions on temporal constraints and on the scheduling
        # constraint graph.
        #
        # It interprets some core Roby relations as schedule_as constraints:
        # - children of the depends_on relation should be scheduled as their parents
        # - children of the planned_by relation should be scheduled as their parents
        #
        # The main difference between the two is the handling of non-executable tasks.
        # In the case of the dependency relation, the child will not be schedulable if
        # the parent is non-executable. It is obviously not the case for the planned_by
        # relation
        #
        # The scheduled_as constraint is "relaxed" in the presence of temporal
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

            def initialize(plan)
                super()

                @plan = plan
            end

            STATE_UNDECIDED = nil
            STATE_SCHEDULABLE = :schedulable
            STATE_NON_SCHEDULABLE = :non_schedulable
            STATE_PENDING_TEMPORAL_CONSTRAINTS = :temporal

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
                relax_scheduling_constraints(scheduling_groups)
                resolve_tasks_to_schedule(scheduling_groups)
            end

            # Return the set of tasks that can be started
            def resolve_tasks_to_schedule(scheduling_groups)
                scheduling_groups.each_vertex.each_with_object(Set.new) do |group, set|
                    next unless group.state == STATE_SCHEDULABLE

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
                    resolve_scheduling_constraints(graph, group, time)
                    scheduling_state_resolve_can_start_group(group)
                    scheduling_state_resolve_temporal_constraints(candidates, group, time)

                    group.state =
                        if !group.can_start || group.external_temporal_constraints
                            STATE_NON_SCHEDULABLE
                        elsif (state = group.scheduling_constraint_state)
                            state
                        else
                            STATE_SCHEDULABLE
                        end

                    queue.concat(propagate_scheduling_next_steps(graph, group))
                end
            end

            def scheduling_state_resolve_can_start_group(group)
                return if (group.can_start = can_start_group?(group))

                group.held_non_schedulable << group
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

            # Try globally resolving the cross-groups temporal constraints so that
            # we schedule tasks that will "unblock" the overall system
            def relax_scheduling_constraints(graph)
                graph.each_vertex do |group|
                    if group.state == STATE_UNDECIDED
                        raise InternalError,
                              "group in STATE_UNDECIDED after propagation"
                    end

                    next unless group.state == STATE_PENDING_TEMPORAL_CONSTRAINTS

                    try_relax_group_scheduling_constraints(group)
                end
            end

            def try_relax_group_scheduling_constraints(group, set: Set.new)
                return false if group.state == STATE_NON_SCHEDULABLE
                return true unless set.add?(group)

                group.held_by_temporal.each do |holding_group|
                    unless try_relax_group_scheduling_constraints(holding_group, set: set)
                        return false
                    end
                end

                group.state = STATE_SCHEDULABLE
                true
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

            SchedulingConstraintResult =
                Struct.new(:held_by_temporal, :held_non_schedulable, keyword_init: true)

            # Register the reasons why a group is held by scheduling constraints
            def resolve_scheduling_constraints(graph, group, _time)
                graph.each_out_neighbour(group) do |scheduled_as_group|
                    group.held_by_temporal.merge(scheduled_as_group.held_by_temporal)
                    group.held_non_schedulable.merge(
                        scheduled_as_group.held_non_schedulable
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

            # Create a graph where u->v indicates that `u` should be schedulable for `v`
            # to be schedulable (the inverse of the schedule_as relation)
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
                graph.merge(@plan.task_relation_graph_for(TaskStructure::PlannedBy))
            end

            # Create the condensed graph of the given scheduling graph, where vertices
            # are instances of SchedulingGroup
            #
            # In the scheduling graph, an edge a->b means that 'a' is scheduled_as 'b'
            def create_scheduling_group_graph(scheduled_as)
                condensed = scheduled_as.condensation_graph

                graph = Relations::BidirectionalDirectedAdjacencyGraph.new
                set_id_to_group = {}
                set_id_to_group.compare_by_identity
                condensed.each_vertex do |u, _v|
                    group = SchedulingGroup.new(tasks: u, held_by_temporal: Set.new,
                                                held_non_schedulable: Set.new)
                    set_id_to_group[u] = group
                    graph.add_vertex(group)
                end

                condensed.each_edge do |u, v|
                    graph.add_edge(set_id_to_group[u], set_id_to_group[v], Set.new)
                end

                graph
            end

            # Test if all conditions that are independent of the task relations are met
            # to start all tasks in the group
            def can_start_group?(group)
                group.tasks.map { |t| can_start?(t) }.all?
            end

            def can_start?(task) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
                unless task.executable?
                    report_pending_non_executable_task("#{task} is not executable", task)
                    return false
                end

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
                :tasks, :temporal_constraints, :held_by_temporal, :held_non_schedulable,
                :state, :can_start, :external_temporal_constraints, keyword_init: true
            ) do
                def each(&block)
                    tasks.each(&block)
                end

                def scheduling_constraint_state
                    return STATE_NON_SCHEDULABLE unless held_non_schedulable.empty?
                    unless held_by_temporal.empty?
                        return STATE_PENDING_TEMPORAL_CONSTRAINTS
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

            # Representation of the resolution state
            #
            # @!method groups
            #   @return [Array<SchedulingGroup>] groups resolved so far
            #
            # @!method task_to_group
            #   @return [Hash<Task, SchedulingGroup>] handled_tasks map from tasks that
            #      have been handled to the group that include them
            Resolution = Struct.new(
                :candidates, :task_to_group, :schedule_graph, :condensed_schedule_graph,
                keyword_init: true
            )

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
        end
    end
end
