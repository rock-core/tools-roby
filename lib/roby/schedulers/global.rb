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
        class Global < Reporting # rubocop:disable Metrics/ClassLength
            extend Logger::Hierarchy
            extend Logger::Forward
            include Logger::Hierarchy
            include Logger::Forward

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
                Roby.log_pp(scheduling_groups, logger, :debug)

                propagate_scheduling_state(candidates, scheduling_groups, time)
                validate_scheduling_state_propagation(scheduling_groups)
                relax_scheduling_constraints(scheduling_groups)
                result = resolve_tasks_to_schedule(scheduling_groups, time)

                debug_output_scheduled_tasks(result)
                result
            end

            def debug_output_scheduled_tasks(result)
                debug do
                    debug "scheduling #{result.size} tasks"
                    result.each do |t|
                        debug "  #{t}"
                    end
                    nil
                end
            end

            # Return the set of tasks that can be started
            def resolve_tasks_to_schedule(scheduling_groups, time)
                scheduling_groups.each_vertex.each_with_object(Set.new) do |group, set|
                    next unless group.state == STATE_SCHEDULABLE

                    debug "#{group.id}: #{group.non_executable_tasks.size}"
                    unless group.non_executable_tasks.empty?
                        report_group_non_executable(group)
                        next
                    end

                    group.resolve_tasks_to_schedule(set, time)
                end
            end

            def report_group_non_executable(group)
                group.tasks.each do |task|
                    report_holdoff "non executable tasks in scheduling group", task
                end
            end

            def report_group_non_relaxable_pending_constraints(group)
                group.tasks.each do |task|
                    report_holdoff(
                        "scheduling group has non-relaxable pending constraints", task
                    )
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

                    group.state = log_nest(2) do
                        group.resolve_state(logger: self)
                    end
                    debug "#{group.id}: in state #{group.state}"

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

                debug_output_group_temporal_constraints(candidates, group)
            end

            # Debug output helper for {#scheduling_state_resolve_temporal_constraints}
            def debug_output_group_temporal_constraints(candidates, group)
                return unless Roby.log_level_enabled?(self, :debug)

                unless group.external_temporal_constraints
                    debug "#{group.id}: has temporal constraints"
                    return
                end

                debug "#{group.id}: has external temporal constraints"
                tasks = group.temporal_constraints.related_tasks
                             .find_all { |task| !candidates.include?(task) }
                tasks.each do |t|
                    debug "  #{t}"
                end
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

            STATES_COMPATIBLE_WITH_RELAXATION =
                [STATE_SCHEDULABLE, STATE_PENDING_CONSTRAINTS].freeze

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
                relaxation_graph = relaxation_create_graph(scheduling_groups)

                scheduling_groups.each_vertex do |group|
                    next unless group.state == STATE_PENDING_CONSTRAINTS

                    relax_group_scheduling_constraints(
                        group, scheduling_groups, relaxation_graph
                    )
                end
            end

            # Perform relaxation on a single group which is in STATE_PENDING_CONSTRAINTS
            #
            # @see relax_scheduling_constraints
            def relax_group_scheduling_constraints(
                group, scheduling_groups, relaxation_graph
            )
                debug "relaxing scheduling constraints on group #{group.id}"

                related = relaxation_compute_related_groups(
                    scheduling_groups, relaxation_graph, group
                )
                unless related
                    debug "  failed, marking #{group.id} as non-schedulable"
                    # In the negative, we can't infer anything about other
                    # groups ... need to re-process them
                    group.state = STATE_NON_SCHEDULABLE
                    report_group_non_relaxable_pending_constraints(group)
                    return
                end

                relaxed = related.all?(&:state_compatible_with_relaxation?)
                unless relaxed
                    debug_relaxed_group_failure(related)
                    return
                end

                debug_relaxed_group(related)
                related.each { |g| g.state = STATE_SCHEDULABLE }
            end

            # @api private
            #
            # Emit the debug messages for {#relax_scheduling_constraints} when a group
            # state was relaxed from PENDING_CONSTRAINTS to SCHEDULABLE
            def debug_relaxed_group(related)
                return unless Roby.log_level_enabled?(self, :debug)

                groups_to_s = related.map(&:id).sort.map(&:to_s).join(", ")
                debug "  found #{related.size} related groups in " \
                      "SCHEDULABLE or PENDING_CONSTRAINTS state, " \
                      "relaxing: #{groups_to_s}"
            end

            # @api private
            #
            # Emit the debug messages for {#relax_scheduling_constraints} when a group
            # state could not be relaxed
            def debug_relaxed_group_failure(related)
                return unless Roby.log_level_enabled?(self, :debug)

                missing = related.find_all { |g| !g.state_compatible_with_relaxation? }

                groups_to_s = related.map(&:id).sort.map(&:to_s).join(", ")
                missing_to_s =
                    missing.sort_by(&:id).map { |g| "#{g.id}[#{g.state}]" }
                debug "  found #{related.size} related groups " \
                      "(#{groups_to_s}) but #{missing.size} are not " \
                      "in either SCHEDULABLE or PENDING_CONSTRAINTS " \
                      "states, leaving state as-is: #{missing_to_s}"
            end

            # Internal graph used by {Global#relax_group_scheduling_constraints}
            #
            # The graph vertices are scheduling groups. An edge u->v represents that
            # 'u' is held by something that should happen in 'v'. The graph allows
            # self-edges
            class RelaxationGraph < Relations::BidirectionalDirectedAdjacencyGraph
                def initialize
                    @self_edges = Set.new
                    @self_edges.compare_by_identity
                    super
                end

                def add_edge(group, holding_group)
                    if group == holding_group
                        add_vertex(group)
                        @self_edges << group
                    else
                        super
                    end
                end

                def out_neighbours(group)
                    neighbours = super
                    neighbours |= [group] if @self_edges.include?(group)
                    neighbours
                end
            end

            # Create a graph on which {#relax_scheduling_constraints} will work
            #
            # This graph represents the 'live' scheduling constraints, that is an edge
            # a->b means that `a` has a schedule_as constraint on `b` and `b` is
            # currently not directly schedulable. This is a transitive relation, that is
            # the out edges of a given group represent all the known constraints
            def relaxation_create_graph(scheduling_groups)
                relaxation_graph = RelaxationGraph.new
                scheduling_groups.each_vertex do |group|
                    next unless group.state == STATE_PENDING_CONSTRAINTS

                    relaxation_add_groups(
                        relaxation_graph, group, group.held_by_temporal
                    )
                    relaxation_add_groups(
                        relaxation_graph, group, group.held_non_executable
                    )
                end
                relaxation_graph
            end

            # Helper for {#relaxation_create_graph}
            def relaxation_add_groups(relaxation_graph, ref, groups)
                groups.each do |holding_group|
                    relaxation_graph.add_edge(ref, holding_group)
                end
            end

            # Compute the set of groups that need to be resolved together to allow
            # for their (collective) scheduling
            def relaxation_compute_related_groups(
                scheduling_groups, relaxation_graph, seed_group
            )
                queue = [seed_group]
                seen_holding_groups = Set.new
                related_groups = Set.new
                until queue.empty?
                    g = queue.shift
                    next unless related_groups.add?(g)

                    dependent_groups = relaxation_compute_single_group_relations(
                        g, seen_holding_groups, scheduling_groups, relaxation_graph
                    )
                    unless dependent_groups
                        debug "  could not relax"
                        return
                    end

                    dependent_groups.compact.map(&:to_a).each do |groups|
                        queue.concat(groups)
                    end
                end

                related_groups
            end

            def relaxation_compute_single_group_relations(
                group, seen_holding_groups, scheduling_groups, relaxation_graph
            )
                holding_groups = relaxation_graph.out_neighbours(group)
                debug_relaxation_show_holding_groups(group, holding_groups)

                holding_groups.map do |holding_g|
                    next unless seen_holding_groups.add?(holding_g)

                    dependent_groups = log_nest(2) do
                        relaxation_compute_dependent_groups(
                            scheduling_groups, holding_g
                        )
                    end
                    break unless dependent_groups

                    dependent_groups
                end
            end

            def debug_relaxation_show_holding_groups(group, holding_groups)
                debug do
                    groups_to_s = holding_groups.map(&:id).sort.map(&:to_s).join(", ")
                    debug "  group #{group.id} held by #{holding_groups.size} groups, " \
                          "trying to relax: #{groups_to_s}"
                    nil
                end
            end

            def relaxation_compute_dependent_groups(scheduling_groups, holding_group)
                dependent_groups = Set.new

                all_planned = relaxation_resolve_non_executable_tasks(
                    dependent_groups, holding_group, scheduling_groups
                )
                unless all_planned
                    debug "could not relax all non-executable tasks"
                    return
                end

                all_valid = relaxation_add_temporal_constraints_to_dependent_groups(
                    dependent_groups, holding_group, scheduling_groups
                )
                unless all_valid
                    debug "could not relax all temporal constraints"
                    return
                end

                dependent_groups
            end

            def relaxation_resolve_non_executable_tasks(
                dependent_groups, holding_group, scheduling_groups
            )
                holding_group.non_executable_tasks.all? do |non_executable_task|
                    resolution_groups =
                        non_executable_resolution_tasks(non_executable_task).map do |t|
                            scheduling_groups.find_planning_task_group(holding_group, t)
                        end

                    resolution_groups = resolution_groups.compact
                    unless resolution_groups.empty?
                        dependent_groups.merge(resolution_groups)
                    end
                end
            end

            # Resolve the set of tasks that can turn a non-executable task into an
            # executable one
            def non_executable_resolution_tasks(non_executable_task)
                @plan.task_relation_graph_for(TaskStructure::PlannedBy)
                     .out_neighbours(non_executable_task)
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

                def pretty_print(pp)
                    pp.text "Scheduling group graph with #{num_vertices} groups"
                    pp.nest(2) do
                        each_vertex do |g|
                            pp.breakable
                            pp_group(pp, g)
                        end
                    end

                    pp.nest(2) do
                        pp.breakable
                        pp.text "#{num_edges} edges"
                        pp.nest(2) do
                            each_edge do |u, v|
                                pp.breakable
                                pp.text "#{u.id}.schedule_as(#{v.id})"
                            end
                        end
                    end
                end

                def pp_group(pp, group)
                    pp.text "[#{group.id}] #{group.tasks.size} tasks"
                    pp.nest(2) do
                        group.tasks.each do |t|
                            pp.breakable
                            pp.text t.to_s
                        end
                    end
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
            #
            # @return [SchedulingGroupsGraph]
            def create_scheduling_group_graph(scheduled_as)
                condensed = scheduled_as.condensation_graph

                graph = SchedulingGroupsGraph.new
                set_id_to_group = {}
                set_id_to_group.compare_by_identity
                condensed.each_vertex do |task_set|
                    group = SchedulingGroup.for_tasks(
                        tasks: task_set, id: set_id_to_group.size
                    )
                    set_id_to_group[task_set] = group
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
                :state, :id, keyword_init: true
            ) do
                def self.for_tasks(tasks:, id:)
                    SchedulingGroup.new(
                        tasks: tasks, id: id,
                        held_by_temporal: Set.new,
                        held_non_schedulable: Set.new,
                        held_non_executable: Set.new,
                        non_executable_tasks: Set.new
                    )
                end

                def each(&block)
                    tasks.each(&block)
                end

                def scheduling_constraint_state(logger: nil)
                    if !held_non_schedulable.empty?
                        logger&.debug "#{id} is held by non-schedulable groups"
                        STATE_NON_SCHEDULABLE
                    elsif !held_non_executable.empty?
                        logger&.debug "#{id} is held by non-executable groups"
                        STATE_PENDING_CONSTRAINTS
                    elsif !held_by_temporal.empty?
                        logger&.debug "#{id} is held by temporal constraints within " \
                              "the scheduling groups"
                        STATE_PENDING_CONSTRAINTS
                    end
                end

                def resolve_state(logger: nil)
                    state = nil

                    debug_output_resolve_state(logger) if logger

                    unless non_executable_tasks.empty?
                        held_non_executable << self
                        state = STATE_PENDING_CONSTRAINTS
                    end

                    if !can_schedule
                        held_non_schedulable << self
                        state = STATE_NON_SCHEDULABLE
                    elsif external_temporal_constraints
                        held_non_schedulable << self
                        state = STATE_NON_SCHEDULABLE
                    else
                        state = scheduling_constraint_state(logger: logger) || state
                    end

                    state || STATE_SCHEDULABLE
                end

                def debug_output_resolve_state(logger)
                    return unless Roby.log_level_enabled?(logger, :debug)

                    unless non_executable_tasks.empty?
                        logger.debug "#{id} has non-executable tasks"
                    end
                    logger.debug "#{id} has !can_schedule" unless can_schedule
                    if external_temporal_constraints
                        logger.debug "#{id} has external temporal constraints"
                    end

                    nil
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

                # Assuming this group can be scheduled, return the tasks that should
                # be scheduled for it
                def resolve_tasks_to_schedule(set, time)
                    if held_by_temporal.empty?
                        set.merge(tasks)
                    else
                        held_by_temporal.each do |group|
                            related_tasks = group.temporal_constraints.related_tasks
                            related_schedulable =
                                find_all_schedulable(related_tasks, time)
                            set.merge(related_schedulable)
                        end
                    end
                end

                def find_all_schedulable(tasks, time)
                    tasks = tasks.find_all(&:executable?)
                    tasks.find_all do |t|
                        start = t.start_event
                        has_failed_temporal =
                            start.each_failed_temporal_constraint(time).any?
                        has_failed_occurence =
                            start.each_failed_occurence_constraint(use_last_event: true)
                                 .any?
                        !has_failed_occurence && !has_failed_temporal
                    end
                end

                # Tests whether this group is in a state that is compatible with
                # state relaxation
                #
                # @see {Global#relax_group_scheduling_constraints}
                def state_compatible_with_relaxation?
                    STATES_COMPATIBLE_WITH_RELAXATION.include?(state)
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
