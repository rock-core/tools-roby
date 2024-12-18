# frozen_string_literal: true

module Roby
    # A plan object manages a collection of tasks and events.
    class Plan < DistributedObject
        extend Logger::Hierarchy
        extend Logger::Forward
        include DRoby::EventLogging

        # The Peer ID of the local owner (i.e. of the local process / execution
        # engine)
        attr_accessor :local_owner

        # The task index for this plan. This is a {Queries::Index} object which allows
        # efficient resolving of queries.
        attr_reader :task_index

        # The list of tasks that are included in this plan
        attr_reader :tasks
        # The set of events that are defined by #tasks
        attr_reader :task_events

        # The set of the robot's missions
        # @see add_mission_task unmark_mission_task
        def mission_tasks
            @task_index.mission_tasks
        end

        # The set of tasks that are kept around "just in case"
        # @see add_permanent_task unmark_permanent_task
        def permanent_tasks
            @task_index.permanent_tasks
        end

        # The list of events that are not included in a task
        attr_reader :free_events

        # The list of events that are kept outside GC. Do not change that set
        # directly, use #permanent and #auto instead.
        def permanent_events
            @task_index.permanent_events
        end

        # A set of pair of task matching objects and blocks defining this plan's
        # triggers
        #
        # See {#add_trigger}
        attr_reader :triggers

        # The set of transactions which are built on top of this plan
        attr_reader :transactions

        # If this object is the main plan, checks if we are subscribed to
        # the whole remote plan
        def sibling_on?(peer)
            if Roby.plan == self then peer.remote_plan
            else
                super
            end
        end

        # The set of PlanService instances that are defined on this plan
        attr_reader :plan_services

        # A template plan is meant to be injected in another plan
        #
        # When a {PlanObject} is included in a template plan, adding relations
        # to other tasks causes the plans to merge as needed. Doing the same
        # operation with plain plans causes an error
        #
        # @see TemplatePlan
        def template?
            false
        end

        # Check that this is an executable plan. This is always true for
        # plain Plan objects and false for transcations
        def executable?
            false
        end

        # The event logger
        attr_accessor :event_logger

        # The observer object that reacts to relation changes
        attr_reader :graph_observer

        def initialize(graph_observer: nil, event_logger: DRoby::NullEventLogger.new)
            @local_owner = DRoby::PeerID.new("local")

            @tasks = Set.new
            @free_events = Set.new
            @task_events = Set.new
            @transactions = Set.new
            @fault_response_tables = []
            @triggers = []

            @plan_services = {}

            self.event_logger = event_logger
            @active_fault_response_tables = []
            @task_index = Roby::Queries::Index.new

            @graph_observer = graph_observer
            create_relations
            create_null_relations

            super()
        end

        def create_null_relations
            @null_task_relation_graphs, @null_event_relation_graphs =
                self.class.instanciate_relation_graphs(graph_observer: graph_observer)
            @null_task_relation_graphs.freeze
            @null_task_relation_graphs.each_value(&:freeze)
            @null_event_relation_graphs.freeze
            @null_event_relation_graphs.each_value(&:freeze)
        end

        def create_relations
            @task_relation_graphs, @event_relation_graphs =
                self.class.instanciate_relation_graphs(graph_observer: graph_observer)

            @structure_checks = []
            each_relation_graph do |graph|
                if graph.respond_to?(:check_structure)
                    structure_checks << graph.method(:check_structure)
                end
            end
        end

        def refresh_relations
            create_relations
            create_null_relations
        end

        def self.instanciate_relation_graphs(graph_observer: nil)
            task_relation_graphs = Relations::Space.new_relation_graph_mapping
            Task.all_relation_spaces.each do |space|
                task_relation_graphs.merge!(
                    space.instanciate(observer: graph_observer)
                )
            end

            event_relation_graphs = Relations::Space.new_relation_graph_mapping
            EventGenerator.all_relation_spaces.each do |space|
                event_relation_graphs.merge!(
                    space.instanciate(observer: graph_observer)
                )
            end
            [task_relation_graphs, event_relation_graphs]
        end

        def dedupe(source)
            @task_relation_graphs.each do |relation, graph|
                if relation != graph
                    graph.dedupe(source.task_relation_graph_for(relation))
                end
            end
            @event_relation_graphs.each do |relation, graph|
                if relation != graph
                    graph.dedupe(source.event_relation_graph_for(relation))
                end
            end
        end

        # The graphs that make task relations, formatted as required by
        # {Relations::DirectedRelationSupport#relation_graphs}
        #
        # @see each_task_relation_graph
        attr_reader :task_relation_graphs

        # A set of empty graphs that match {#task_relation_graphs}
        #
        # Used for finalized tasks
        attr_reader :null_task_relation_graphs

        # The graphs that make event relations, formatted as required by
        # {Relations::DirectedRelationSupport#relation_graphs}
        #
        # @see each_event_relation_graph
        attr_reader :event_relation_graphs

        # A set of empty graphs that match {#event_relation_graphs}
        #
        # Used for finalized events
        attr_reader :null_event_relation_graphs

        # Enumerate all graphs (event and tasks) that form this plan
        def each_relation_graph(&block)
            return enum_for(__method__) unless block_given?

            each_task_relation_graph(&block)
            each_event_relation_graph(&block)
        end

        # Enumerate the graph objects that contain this plan's event relation
        # information
        #
        # @yieldparam [Relations::EventRelationGraph] graph
        def each_event_relation_graph
            return enum_for(__method__) unless block_given?

            event_relation_graphs.each do |k, v|
                yield(v) if k == v
            end
        end

        # Resolves an event graph object from the graph class (i.e. the graph model)
        def event_relation_graph_for(model)
            event_relation_graphs.fetch(model)
        end

        # Enumerate the graph objects that contain this plan's task relation
        # information
        #
        # @yieldparam [Relations::TaskRelationGraph] graph
        def each_task_relation_graph
            return enum_for(__method__) unless block_given?

            task_relation_graphs.each do |k, v|
                yield(v) if k == v
            end
        end

        # Resolves a task graph object from the graph class (i.e. the graph model)
        def task_relation_graph_for(model)
            task_relation_graphs.fetch(model)
        end

        def dup
            new_plan = Plan.new
            copy_to(new_plan)
            new_plan
        end

        def inspect # :nodoc:
            "#<#{self}: mission_tasks=#{mission_tasks} tasks=#{tasks} "\
            "events=#{free_events} transactions=#{transactions}>"
        end

        # Calls the given block in the execution thread of this plan's engine.
        # If there is no engine attached to this plan, yields immediately
        #
        # See ExecutionEngine#execute
        def execute
            yield
        end

        # @deprecated use {#merge} instead
        def copy_to(copy)
            copy.merge(self)
        end

        def merge_base(plan)
            free_events.merge(plan.free_events)
            mission_tasks.merge(plan.mission_tasks)
            tasks.merge(plan.tasks)
            permanent_tasks.merge(plan.permanent_tasks)
            permanent_events.merge(plan.permanent_events)
            task_index.merge(plan.task_index)
            task_events.merge(plan.task_events)
        end

        def merge_relation_graphs(plan)
            # Now merge the relation graphs
            #
            # Since task_relation_graphs contains both Class<Graph>=>Graph and
            # Graph=>Graph, we merge only the graphs for which
            # self.task_relation_graphs has an entry (i.e. Class<Graph>) and
            # ignore the rest
            plan.task_relation_graphs.each do |rel_id, rel|
                next if rel_id == rel

                this_rel = task_relation_graphs.fetch(rel_id, nil)
                next unless this_rel

                this_rel.merge(rel)
            end
            plan.event_relation_graphs.each do |rel_id, rel|
                next if rel_id == rel

                this_rel = event_relation_graphs.fetch(rel_id, nil)
                next unless this_rel

                this_rel.merge(rel)
            end
        end

        def replace_relation_graphs(merged_graphs)
            merged_graphs.each do |self_g, new_g|
                self_g.replace(new_g)
            end
        end

        def merge_transaction(transaction, merged_graphs, _added, _removed, _updated)
            merging_plan(transaction)
            merge_base(transaction)
            replace_relation_graphs(merged_graphs)
            merged_plan(transaction)
        end

        def merge_transaction!(transaction, merged_graphs, added, removed, updated)
            # NOTE: Task#plan= updates its bound events
            tasks = transaction.tasks.dup
            events = transaction.free_events.dup
            tasks.each { |t| t.plan = self }
            events.each { |e| e.plan = self }

            merge_transaction(transaction, merged_graphs, added, removed, updated)
        end

        def find_triggers_matches(plan)
            triggers.map do |tr|
                [tr, tr.each(plan).to_a]
            end
        end

        def apply_triggers_matches(matches)
            matches.each do |trigger, matched_tasks|
                matched_tasks.each do |t|
                    trigger.call(t)
                end
            end
        end

        # Merges the content of a plan into self
        #
        # It is assumed that self and plan do not intersect.
        #
        # Unlike {#merge!}, it does not update its argument, neither update the
        # plan objects to point to self afterwards
        #
        # @param [Roby::Plan] plan the plan to merge into self
        def merge(plan)
            return if plan == self

            trigger_matches = find_triggers_matches(plan)
            merging_plan(plan)
            merge_base(plan)
            merge_relation_graphs(plan)
            merged_plan(plan)
            apply_triggers_matches(trigger_matches)
        end

        # Moves the content of other_plan into self, and clears other_plan
        #
        # It is assumed that other_plan and plan do not intersect
        #
        # Unlike {#merge}, it ensures that all plan objects have their
        # {PlanObject#plan} attribute properly updated, and it cleans plan
        #
        # @param [Roby::Plan] plan the plan to merge into self
        def merge!(plan)
            return if plan == self

            tasks = plan.tasks.dup
            events = plan.free_events.dup
            tasks.each { |t| t.plan = self }
            events.each { |e| e.plan = self }
            merge(plan)
        end

        # Hook called just before performing a {#merge}
        def merging_plan(plan); end

        # Hook called when a {#merge} has been performed
        def merged_plan(plan); end

        def deep_copy
            plan = Roby::Plan.new
            mappings = deep_copy_to(plan)
            [plan, mappings]
        end

        # Copies this plan's state (tasks, events and their relations) into the
        # provided plan
        #
        # It returns the mapping from the plan objects in +self+ to the plan
        # objects in +copy+. For instance, if +t+ is a task in +plan+, then
        #
        #   mapping = plan.copy_to(copy)
        #   mapping[t] => corresponding task in +copy+
        def deep_copy_to(copy)
            mappings = Hash.new do |_, k|
                if !include?(k)
                    raise InternalError,
                          "#{k} is listed in a relation, but is not included "\
                          "in the corresponding plan #{self}"
                else
                    raise InternalError,
                          "#{k} is an object in #{self} for which no mapping "\
                          "has been created in #{copy}"
                end
            end

            # First create a copy of all the tasks
            tasks.each do |t|
                new_t = t.dup
                mappings[t] = new_t

                t.each_event do |ev|
                    new_ev = ev.dup
                    new_ev.instance_variable_set :@task, new_t
                    new_t.bound_events[ev.symbol] = new_ev
                    mappings[ev] = new_ev
                end

                copy.register_task(new_t)
                new_t.each_event do |ev|
                    copy.register_event(ev)
                end
            end
            free_events.each do |e|
                new_e = e.dup
                mappings[e] = new_e
                copy.register_event(new_e)
            end

            mission_tasks.each { |t| copy.add_mission_task(mappings[t]) }
            permanent_tasks.each { |t| copy.add_permanent_task(mappings[t]) }
            permanent_events.each { |e| copy.add_permanent_event(mappings[e]) }

            copy_relation_graphs_to(copy, mappings)
            mappings
        end

        def copy_relation_graphs_to(copy, mappings)
            each_task_relation_graph do |graph|
                target_graph = copy.task_relation_graph_for(graph.class)
                graph.each_edge do |parent, child|
                    target_graph.add_edge(
                        mappings[parent], mappings[child], graph.edge_info(parent, child)
                    )
                end
            end

            each_event_relation_graph do |graph|
                target_graph = copy.event_relation_graph_for(graph.class)
                graph.each_edge do |parent, child|
                    target_graph.add_edge(
                        mappings[parent], mappings[child], graph.edge_info(parent, child)
                    )
                end
            end
        end

        # Verifies that all graphs that should be acyclic are
        def validate_graphs(graphs)
            # Make a topological sort of the graphs
            seen = Set.new
            Relations.each_graph_topologically(graphs) do |g|
                next if seen.include?(g)
                next unless g.dag?
                unless g.acyclic?
                    raise Relations::CycleFoundError, "#{g.class} has cycles"
                end

                seen << g
                seen.merge(g.recursive_subsets)
            end
        end

        # @api private
        #
        # Normalize an validate the arguments to {#add} into a list of plan objects
        def normalize_add_arguments(objects)
            objects = [objects] unless objects.respond_to?(:each)

            objects.map do |o|
                if o.respond_to?(:as_plan) then o.as_plan
                elsif o.respond_to?(:to_event) then o.to_event
                elsif o.respond_to?(:to_task) then o.to_task
                else
                    raise ArgumentError,
                          "found #{o || 'nil'} which is neither a task nor an event"
                end
            end
        end

        # If this plan is a toplevel plan, returns self. If it is a
        # transaction, returns the underlying plan
        def real_plan
            ret = self
            ret = ret.plan while ret.respond_to?(:plan)
            ret
        end

        # True if this plan is root in the plan hierarchy
        def root_plan?
            true
        end

        # Returns the set of stacked transaction
        #
        # @return [Array] the list of plans in the transaction stack, the first
        #   element being the most-nested transaction and the last element the
        #   underlying real plan (equal to {#real_plan})
        def transaction_stack
            plan_chain = [self]
            plan_chain << plan_chain.last.plan while plan_chain.last.respond_to?(:plan)
            plan_chain
        end

        # @deprecated use {#add_mission_task} instead
        def add_mission(task)
            Roby.warn_deprecated(
                "#add_mission is deprecated, use #add_mission_task instead"
            )
            add_mission_task(task)
        end

        # @deprecated use {#mission_task?} instead
        def mission?(task)
            Roby.warn_deprecated "#mission? is deprecated, use #mission_task? instead"
            mission_task?(task)
        end

        # @deprecated use {#unmark_mission_task} instead
        def unmark_mission(task)
            Roby.warn_deprecated(
                "#unmark_mission is deprecated, use #unmark_mission_task instead"
            )
            unmark_mission_task(task)
        end

        # Add a task to the plan's set of missions
        #
        # A mission represents the system's overall goal. As such a mission task
        # and all its dependencies are protected against the garbage collection
        # mechanisms, and the emission of a mission's failed event causes a
        # MissionFailedError exception to be generated.
        #
        # Note that this method should be used to add the task to the plan and
        # mark it as mission, and to mark an already added task as mission as
        # well.
        #
        # @see mission_task? unmark_mission_task
        def add_mission_task(task)
            task = normalize_add_arguments([task]).first
            return if mission_tasks.include?(task)

            add([task])
            mission_tasks << task
            task.mission = true if task.self_owned?
            notify_task_status_change(task, :mission)
            task
        end

        # Add an action as a job
        def add_job_action(action)
            add_mission_task(
                action.as_plan(job_id: Roby::Interface::Job.allocate_job_id)
            )
        end

        # Checks if a task is part of the plan's missions
        #
        # @see add_mission_task unmark_mission_task
        def mission_task?(task)
            @task_index.mission_tasks.include?(task.to_task)
        end

        # Removes a task from the plan's missions
        #
        # It does not remove the task from the plan. In a plan that is being
        # executed, it is done by garbage collection. In a static plan, it can
        # either be done with {#static_garbage_collect} or directly by calling
        # {#remove_task} or {#remove_free_event}
        #
        # @see add_mission_task mission_task?
        def unmark_mission_task(task)
            task = task.to_task
            return unless @task_index.mission_tasks.include?(task)

            @task_index.mission_tasks.delete(task)
            task.mission = false if task.self_owned?
            notify_task_status_change(task, :normal)
            self
        end

        # @deprecated use {#add_permanent_task} or {#add_permanent_event} instead
        def add_permanent(object)
            Roby.warn_deprecated(
                "#add_permanent is deprecated, use either #add_permanent_task "\
                "or #add_permanent_event instead"
            )
            object = normalize_add_arguments([object]).first
            if object.respond_to?(:to_task)
                add_permanent_task(object)
            else
                add_permanent_event(object)
            end
            object
        end

        # @deprecated use {#unmark_permanent_task} or {#unmark_permanent_event} instead
        def unmark_permanent(object)
            Roby.warn_deprecated(
                "#unmark_permanent is deprecated, use either #unmark_permanent_task "\
                "or #unmark_permanent_event"
            )

            if object.respond_to?(:to_task)
                unmark_permanent_task(object)
            elsif object.respond_to?(:to_event)
                unmark_permanent_event(object)
            else
                raise ArgumentError, "expected a task or event and got #{object}"
            end
        end

        # @deprecated use {#permanent_task?} or {#permanent_event?} instead
        def permanent?(object)
            Roby.warn_deprecated(
                "#permanent? is deprecated, use either "\
                "#permanent_task? or #permanent_event?"
            )

            if object.respond_to?(:to_task)
                permanent_task?(object)
            elsif object.respond_to?(:to_event)
                permanent_event?(object)
            else
                raise ArgumentError, "expected a task or event and got #{object}"
            end
        end

        # Mark a task as permanent, optionally adding to the plan
        #
        # Permanent tasks are protected against garbage collection. Like
        # missions, failure of a permanent task will generate a plan exception
        # {PermanentTaskError}. Unlike missions, this exception is non-fatal.
        def add_permanent_task(task)
            task = normalize_add_arguments([task]).first
            return if permanent_tasks.include?(task)

            add([task])
            permanent_tasks << task
            notify_task_status_change(task, :permanent)
            task
        end

        # True if the given task is registered as a permanent task on self
        def permanent_task?(task)
            @task_index.permanent_tasks.include?(task)
        end

        # Removes a task from the set of permanent tasks
        #
        # This does not remove the event from the plan. In plans being executed,
        # the removal will be done by garabage collection. In plans used as data
        # structures, either use {#static_garbage_collect} or remove the event
        # directly with {#remove_task} or {#remove_free_event}
        #
        # @see add_permanent_event permanent_event?
        def unmark_permanent_task(task)
            if @task_index.permanent_tasks.delete?(task.to_task)

                notify_task_status_change(task, :normal)
            end
            nil
        end

        # Mark an event as permanent, optionally adding to the plan
        #
        # Permanent events are protected against garbage collection
        def add_permanent_event(event)
            event = normalize_add_arguments([event]).first
            return if permanent_events.include?(event)

            add([event])
            permanent_events << event
            notify_event_status_change(event, :permanent)
            event
        end

        # True if the given event is registered as a permanent event on self
        def permanent_event?(generator)
            @task_index.permanent_events.include?(generator)
        end

        # Removes a task from the set of permanent tasks
        #
        # This does not remove the event from the plan. In plans being executed,
        # the removal will be done by garabage collection. In plans used as data
        # structures, either use {#static_garbage_collect} or remove the event
        # directly with {#remove_task} or {#remove_free_event}
        #
        # @see add_permanent_event permanent_event?
        def unmark_permanent_event(event)
            if @task_index.permanent_events.delete?(event.to_event)
                notify_event_status_change(event, :normal)
            end
            nil
        end

        # @api private
        #
        # Perform notifications related to the status change of a task
        def notify_task_status_change(task, status)
            if (services = plan_services[task])
                services.each { |s| s.notify_task_status_change(status) }
            end
            log(:task_status_change, task, status)
        end

        # @api private
        #
        # Perform notifications related to the status change of an event
        def notify_event_status_change(event, status)
            log(:event_status_change, event, status)
        end

        def edit
            yield if block_given?
        end

        # True if this plan owns the given object, i.e. if all the owners of the
        # object are also owners of the plan.
        def owns?(object)
            (object.owners - owners).empty?
        end

        def force_replace_task(from, to)
            handle_force_replace(from, to) do
                from.replace_by(to)
            end
        end

        def force_replace(from, to)
            handle_force_replace(from, to) do
                from.replace_subplan_by(to)
            end
        end

        def handle_force_replace(from, to)
            if !from.plan
                raise ArgumentError,
                      "#{from} has been removed from plan, "\
                      "cannot use as source in a replacement"
            elsif !to.plan
                raise ArgumentError,
                      "#{to} has been removed from plan, "\
                      "cannot use as target in a replacement"
            elsif from.plan != self
                raise ArgumentError,
                      "trying to replace #{from} but its plan "\
                      "is #{from.plan}, expected #{self}"
            elsif to.plan.template?
                add(to)
            elsif to.plan != self
                raise ArgumentError,
                      "trying to replace #{to} but its plan "\
                      "is #{to.plan}, expected #{self}"
            elsif from == to
                return
            end

            # Swap the subplans of +from+ and +to+
            yield(from, to)

            if mission_task?(from)
                add_mission_task(to)
                replaced(from, to)
                unmark_mission_task(from)
            elsif permanent_task?(from)
                add_permanent_task(to)
                replaced(from, to)
                unmark_permanent_task(from)
            else
                add(to)
                replaced(from, to)
            end
        end

        def handle_replace(from, to) # :nodoc:
            handle_force_replace(from, to) do
                # Check that +to+ is valid in all hierarchy relations where
                # +from+ is a child
                unless to.fullfills?(*from.fullfilled_model)
                    models = from.fullfilled_model.first
                    missing = models.find_all do |m|
                        !to.fullfills?(m)
                    end
                    if missing.empty?
                        mismatching_argument =
                            from.fullfilled_model.last.find do |key, expected_value|
                                to.arguments.set?(key) &&
                                    (to.arguments[key] != expected_value)
                            end
                    end

                    if mismatching_argument
                        raise InvalidReplace.new(from, to),
                              "argument mismatch for #{mismatching_argument.first}"
                    elsif !missing.empty?
                        raise InvalidReplace.new(from, to),
                              "missing provided models #{missing.map(&:name).join(', ')}"
                    else
                        raise InvalidReplace.new(from, to),
                              "#{to} does not fullfill #{from}"
                    end
                end

                # Swap the subplans of +from+ and +to+
                yield(from, to)
            end
        end

        # Representation for a filter used to exclude tasks or graphs from a replacement
        #
        # Relations to excluded tasks are not moved to the replacing task.
        # Edges from excluded relations or graphs are not moved.
        #
        # It is a fluid interface, i.e. meant to be used as in:
        #
        #     ReplacementFilter.new.exclude_task(excluded).exclude_graph(graph)
        #
        # @see Plan#replace Plan#replace_task
        class ReplacementFilter
            # A {ReplacementFilter} that excludes nothing
            class Null
                def excluded_task?(task); end

                def excluded_graph?(graph); end

                def excluded_relation?(relation); end
            end

            def initialize
                @tasks = Set.new
                @tasks.compare_by_identity
                @graphs = []
                @relations = []
            end

            # Exclude a set of tasks
            #
            # @param [#each] tasks a set of task
            # @return self
            def exclude_tasks(tasks)
                @tasks.merge(tasks)
                self
            end

            # Exclude a single task
            #
            # @param [Task] task the task to be excluded
            # @return self
            def exclude_task(task)
                @tasks << task
                self
            end

            # Tests whether a task is to be excluded
            #
            # @param [Task] task
            def excluded_task?(task)
                @tasks.include?(task)
            end

            # Excludes a graph
            #
            # None of this graph's edges will be moved during the replacement
            #
            # @param [Relations::BidirectionalDirectedAdjacencyGraph] graph
            # @return self
            def exclude_graph(graph)
                @graphs << graph
                self
            end

            # Whether a graph is excluded
            #
            # No edge from an excluded graph will be excluded
            #
            # @param [Relations::Graph] graph
            # @return self
            def excluded_graph?(graph)
                @graphs.include?(graph)
            end

            # Excludes a relation
            #
            # @param [Relations::Models::Graph] graph the graph model
            # @return self
            def exclude_relation(relation)
                @relations << relation
                self
            end

            # Whether a relation is excluded
            #
            # @param [Relations::Models::Graph] graph the graph model
            # @return self
            def excluded_relation?(relation)
                @relations.include?(relation)
            end
        end

        # Replace the task +from+ by +to+ in all relations +from+ is part of
        # (including events).
        #
        # See also #replace
        def replace_task(from, to, filter: ReplacementFilter::Null.new)
            handle_replace(from, to) do
                from.replace_by(to, filter: filter)
            end
        end

        # Replace +from+ by +to+ in the plan, in all relations in which +from+
        # and its events are /children/. It therefore replaces the subplan
        # generated by +from+ (i.e. +from+ and all the tasks/events that can be
        # reached by following the task and event relations) by the subplan
        # generated by +to+.
        #
        # See also #replace_task
        def replace(from, to, filter: ReplacementFilter::Null.new)
            handle_replace(from, to) do
                from.replace_subplan_by(to, filter: filter)
            end
        end

        # Register a new plan service on this plan
        def add_plan_service(service)
            if service.task.plan != self
                raise ArgumentError,
                      "trying to register a plan service on #{self} for "\
                      "#{service.task}, which is included in #{service.task.plan}"
            end

            set = (plan_services[service.task] ||= Set.new)
            set << service
            self
        end

        # Deregisters a plan service from this plan
        def remove_plan_service(service)
            return unless (set = plan_services[service.task])

            set.delete(service)
            plan_services.delete(service.task) if set.empty?
        end

        # Whether there are services registered for the given task
        def registered_plan_services_for(task)
            @plan_services[task] || Set.new
        end

        # Change the actual task a given plan service is representing
        def move_plan_service(service, new_task)
            return if new_task == service.task

            remove_plan_service(service)
            service.task = new_task
            add_plan_service(service)
        end

        # Find all the defined plan services for a given task
        def find_all_plan_services(task)
            plan_services[task] || []
        end

        # If at least one plan service is defined for +task+, returns one of
        # them. Otherwise, returns nil.
        def find_plan_service(task)
            plan_services[task]&.first
        end

        # Replace subgraphs by another in the plan
        #
        # It copies relations that are not within the keys in task_mappings and
        # event_mappings to the corresponding task/events. The targets might be
        # nil, in which case the relations involving the source will be simply
        # ignored.
        #
        # If needed, instead of providing an object as target, one can provide a
        # resolver object which will be called with #call and the source, The
        # resolver should be given as a second element of a pair, e.g.
        #
        #    source => [nil, #call]
        #
        def replace_subplan(
            task_mappings, event_mappings, task_children: true, event_children: true
        )
            new_relations, removed_relations =
                compute_subplan_replacement(task_mappings, each_task_relation_graph,
                                            child_objects: task_children)
            apply_replacement_operations(new_relations, removed_relations)

            new_relations, removed_relations =
                compute_subplan_replacement(event_mappings, each_event_relation_graph,
                                            child_objects: event_children)
            apply_replacement_operations(new_relations, removed_relations)
        end

        # @api private
        def compute_subplan_replacement(mappings, relation_graphs, child_objects: true)
            mappings = mappings.dup
            mappings.compare_by_identity
            new_relations = []
            removed_relations = []
            relation_graphs.each do |graph|
                next if graph.strong?

                resolved_mappings = {}
                resolved_mappings.compare_by_identity
                mappings.each do |obj, (mapped_obj, mapped_obj_resolver)|
                    next if !mapped_obj && !mapped_obj_resolver

                    graph.each_in_neighbour(obj) do |parent|
                        next if mappings.key?(parent)

                        unless graph.copy_on_replace?
                            removed_relations << [graph, parent, obj]
                        end
                        unless mapped_obj
                            mapped_obj = mapped_obj_resolver.call(obj)
                            resolved_mappings[obj] = mapped_obj
                        end
                        new_relations << [
                            graph, parent, mapped_obj, graph.edge_info(parent, obj)
                        ]
                    end

                    next unless child_objects

                    graph.each_out_neighbour(obj) do |child|
                        next if mappings.key?(child)

                        unless graph.copy_on_replace?
                            removed_relations << [graph, obj, child]
                        end
                        unless mapped_obj
                            mapped_obj = mapped_obj_resolver.call(obj)
                            resolved_mappings[obj] = mapped_obj
                        end
                        new_relations << [
                            graph, mapped_obj, child, graph.edge_info(obj, child)
                        ]
                    end
                end
                mappings.merge!(resolved_mappings)
            end
            [new_relations, removed_relations]
        end

        def apply_replacement_operations(new_relations, removed_relations)
            removed_relations.each do |graph, parent, child|
                graph.remove_relation(parent, child)
            end
            new_relations.each do |graph, parent, child, info|
                graph.add_relation(parent, child, info)
            end
        end

        # Hook called when +replacing_task+ has replaced +replaced_task+ in this plan
        def replaced(replaced_task, replacing_task)
            # Make the PlanService object follow the replacement
            return unless (services = plan_services.delete(replaced_task))

            services.each do |srv|
                srv.task = replacing_task
                (plan_services[replacing_task] ||= Set.new) << srv
            end
        end

        # @api private
        #
        # Registers a task object in this plan
        #
        # It is for Roby internal usage only, for the creation of template
        # plans. Use {#add}.
        def register_task(task)
            task.plan = self
            tasks << task
            task_index.add(task)
            task_events.merge(task.each_event)
        end

        # @api private
        #
        # Registers a task object in this plan
        #
        # It is for Roby internal usage only, for the creation of template
        # plans. Use {#add}.
        def register_event(event)
            event.plan = self
            if event.root_object?
                free_events << event
            else
                task_events << event
            end
        end

        # call-seq:
        #   plan.add(task) => plan
        #   plan.add(event) => plan
        #   plan.add([task, event, task2, ...]) => plan
        #   plan.add([t1, t2, ...]) => plan
        #
        # Adds the subplan of the given tasks and events into the plan.
        #
        # That means that it adds the listed tasks/events and the task/events
        # that are reachable through any relations).
        def add(objects)
            is_scalar = objects.respond_to?(:each)
            objects = normalize_add_arguments(objects)

            plans = Set.new
            objects.each do |plan_object|
                p = plan_object.plan
                next if p == self

                if plan_object.removed_at
                    raise ArgumentError,
                          "cannot add #{plan_object} in #{self}, "\
                          "it has been removed from the plan"
                elsif !p
                    raise InternalError,
                          "there seem to be an inconsistency, #{plan_object}#plan "\
                          "is nil but #removed_at is not set"
                elsif p.empty?
                    raise InternalError,
                          "there seem to be an inconsistency, #{plan_object} "\
                          "is associated with #{p} but #{p} is empty"
                elsif !p.template?
                    raise ModelViolation,
                          "cannot add #{plan_object} in #{self}, "\
                          "it is already included in #{p}"
                end
                plans << p
            end

            plans.each do |p|
                merge!(p)
            end

            if is_scalar
                objects.first
            else
                objects
            end
        end

        # @api private
        #
        # A trigger created by {Plan#add_trigger}
        class Trigger
            # The query that is being watched
            attr_reader :query
            # The block that will be called if {#query} matches
            attr_reader :block

            def initialize(query, block)
                @query = query.query
                @block = block
            end

            # Whether self would be triggering on task
            #
            # @param [Roby::Task] task
            # @return [Boolean]
            def ===(task)
                query === task
            end

            # Lists the tasks that match the query
            #
            # @param [Plan] plan
            # @yieldparam [Roby::Task] task tasks that match {#query}
            def each(plan, &block)
                query.plan = plan
                query.reset
                query.each(&block)
            end

            # Call the trigger's observer for the given task
            def call(task)
                block.call(task)
            end
        end

        # Add a trigger
        #
        # This registers a notification: the given block will be called for each
        # new task that match the given query object. It yields right away for
        # the tasks that are already in the plan
        #
        # @param [#===] query_object the object against which tasks are tested.
        #   Tasks for which #=== returns true are yield to the block
        # @yieldparam [Roby::Task] task the task that matched the query object
        # @return [Object] an ID object that can be used in {#remove_trigger}
        def add_trigger(query_object, &block)
            tr = Trigger.new(query_object, block)
            triggers << tr
            tr.each(self) do |t|
                tr.call(t)
            end
            tr
        end

        # Removes a trigger
        #
        # @param [Object] trigger the trigger to be removed. This is the return value of
        #   the corresponding {#add_trigger} call
        # @return [void]
        def remove_trigger(trigger)
            triggers.delete(trigger)
            nil
        end

        # Creates a new transaction and yields it. Ensures that the transaction
        # is discarded if the block returns without having committed it.
        def in_transaction
            yield(trsc = Transaction.new(self))
        ensure
            trsc.discard_transaction if trsc && !trsc.finalized?
        end

        # Hook called when a new transaction has been built on top of this plan
        def added_transaction(trsc); end

        # Removes the transaction +trsc+ from the list of known transactions
        # built on this plan
        def remove_transaction(trsc)
            transactions.delete(trsc)
        end

        # @api private
        #
        # Default set of graphs that should be discovered by
        # {#compute_useful_tasks}
        def default_useful_task_graphs
            each_task_relation_graph.find_all { |g| g.root_relation? && !g.weak? }
        end

        # @api private
        #
        # Compute the subplan that is useful for a given set of tasks
        #
        # @param [Set<Roby::Task>] seeds the root "useful" tasks
        # @param [Array<Relations::BidirectionalDirectedAdjancencyGraph>] graphs the
        #   graphs through which "usefulness" is propagated
        # @return [Set] the set of tasks reachable from 'seeds' through the graphs
        def compute_useful_tasks(seeds, graphs: default_useful_task_graphs)
            seeds = seeds.to_set
            visitors = graphs.map do |g|
                [g, RGL::DFSVisitor.new(g), seeds.dup]
            end

            result = seeds.dup

            has_queued_nodes = true
            while has_queued_nodes
                has_queued_nodes = false
                visitors.each do |graph, visitor, queue|
                    next if queue.empty?

                    new_queue = []
                    queue.each do |vertex|
                        if !visitor.finished_vertex?(vertex) && graph.has_vertex?(vertex)
                            graph.depth_first_visit(vertex, visitor) do |v|
                                yield(v) if block_given?
                                new_queue << v
                            end
                        end
                    end
                    unless new_queue.empty?
                        has_queued_nodes = true
                        result.merge(new_queue)
                        visitors.each { |g, _, s| s.merge(new_queue) if g != graph }
                    end
                    queue.clear
                end
            end

            result
        end

        def locally_useful_roots(with_transactions: true)
            # Create the set of tasks which must be kept as-is
            seeds = @task_index.mission_tasks | @task_index.permanent_tasks
            if with_transactions
                transactions.each do |trsc|
                    seeds.merge trsc.proxy_tasks.keys.to_set
                end
            end
            seeds
        end

        def locally_useful_tasks
            compute_useful_tasks(locally_useful_roots)
        end

        def useful_tasks(additional_roots: Set.new, with_transactions: true)
            compute_useful_tasks(
                locally_useful_roots(with_transactions: with_transactions) |
                additional_roots
            )
        end

        def unneeded_tasks(additional_useful_roots: Set.new)
            tasks - useful_tasks(additional_roots: additional_useful_roots)
        end

        def local_tasks
            task_index.self_owned
        end

        def remote_tasks
            if (local_tasks = task_index.self_owned)
                tasks - local_tasks
            else
                tasks
            end
        end

        # Return all mission/permanent tasks that current depend on the given task
        def useful_tasks_using(tasks)
            all_tasks = compute_useful_tasks(
                Array(tasks), graphs: default_useful_task_graphs.map(&:reverse)
            ).to_set
            all_tasks.compare_by_identity

            result = []
            @task_index.mission_tasks.dup.each do |t|
                result << t if all_tasks.include?(t)
            end
            @task_index.permanent_tasks.dup.each do |t|
                result << t if all_tasks.include?(t)
            end
            result
        end

        # Unmark mission/permanent tasks that depend on the tasks given as argument
        #
        # By doing so, it makes the tasks eligible for garbage collection. This
        # is mostly used to shut down tasks from a specific task within their
        # dependency graph.
        def make_useless(tasks)
            all_tasks = compute_useful_tasks(
                Array(tasks), graphs: default_useful_task_graphs.map(&:reverse)
            ).to_set
            all_tasks.compare_by_identity
            @task_index.mission_tasks.dup.each do |t|
                unmark_mission_task(t) if all_tasks.include?(t)
            end
            @task_index.permanent_tasks.dup.each do |t|
                unmark_permanent_task(t) if all_tasks.include?(t)
            end
        end

        # Computes the set of useful tasks and checks that +task+ is in it.
        # This is quite slow. It is here for debugging purposes. Do not use it
        # in production code
        def useful_task?(task)
            tasks.include?(task) && !unneeded_tasks.include?(task)
        end

        class UsefulFreeEventVisitor < RGL::DFSVisitor
            attr_reader :useful_free_events, :task_events, :stack

            def initialize(graph, task_events, permanent_events)
                super(graph)
                @task_events = task_events
                @useful_free_events = permanent_events.dup
                @useful = false
            end

            def useful?
                @useful
            end

            def handle_examine_edge(_u, v)
                if task_events.include?(v) || useful_free_events.include?(v)
                    color_map[v] = :BLACK
                    @useful = true
                end
                nil
            end

            def follow_edge?(_u, v)
                !task_events.include?(v)
            end
        end

        # @api private
        #
        # Compute the set of events that are "useful" to the plan.
        #
        # It contains every event that is connected to an event in
        # {#permanent_events} or to an event on a task in the plan
        #
        # @return [Set<EventGenerator>]
        def compute_useful_free_events
            # Quick path for a very common case
            return Set.new if free_events.empty?

            graphs = each_event_relation_graph
                     .find_all { |g| g.root_relation? && !g.weak? }

            seen = Set.new
            result = permanent_events.dup
            pending_events = free_events.to_a
            until pending_events.empty?
                # This basically computes the subplan that contains "seed" and
                # determines if it is useful or not
                seed = pending_events.shift
                next if seen.include?(seed)

                visitors = []
                graphs.each do |g|
                    visitors << [
                        g, UsefulFreeEventVisitor.new(
                            g, task_events, permanent_events
                        ),
                        [seed].to_set
                    ]
                    visitors << [
                        g.reverse,
                        UsefulFreeEventVisitor.new(
                            g.reverse, task_events, permanent_events
                        ),
                        [seed].to_set
                    ]
                end

                component = [seed].to_set
                has_pending_seeds = true
                while has_pending_seeds
                    has_pending_seeds = false
                    visitors.each do |graph, visitor, seeds|
                        next if seeds.empty?

                        new_seeds = []
                        seeds.each do |vertex|
                            next if visitor.finished_vertex?(vertex)
                            next unless graph.has_vertex?(vertex)

                            graph.depth_first_visit(vertex, visitor) do |v|
                                new_seeds << v
                            end
                        end

                        unless new_seeds.empty?
                            has_pending_seeds = true
                            component.merge(new_seeds)
                            visitors.each { |g, _, s| s.merge(new_seeds) if g != graph }
                        end
                        seeds.clear
                    end
                end
                seen.merge(component)
                result.merge(component) if visitors.any? { |_, v, _| v.useful? }
            end

            result
        end

        # Computes the set of events that are useful in the plan Events are
        # 'useful' when they are chained to a task.
        def useful_events
            compute_useful_free_events
        end

        # The set of events that can be removed from the plan
        def unneeded_events
            useful_events = self.useful_events

            result = (free_events - useful_events)
            result.delete_if do |ev|
                transactions.any? { |trsc| trsc.find_local_object_for_event(ev) }
            end
            result
        end

        # The number of tasks
        def num_tasks
            tasks.size
        end

        # The number of events that are not task events
        def num_free_events
            free_events.size
        end

        # The number of events, both free and task events
        def num_events
            task_events.size + free_events.size
        end

        # Tests whether a task is present in this plan
        def has_task?(task)
            tasks.include?(task)
        end

        # Tests whether a task event is present in this plan
        def has_task_event?(generator)
            task_events.include?(generator)
        end

        # Tests whether a free event is present in this plan
        def has_free_event?(generator)
            free_events.include?(generator)
        end

        # @deprecated use the more specific {#has_task?}, {#has_free_event?} or
        #   {#has_task_event?} instead
        def include?(object)
            Roby.warn_deprecated(
                "Plan#include? is deprecated, use one of the more specific "\
                "#has_task? #has_task_event? and #has_free_event?"
            )
            has_free_event?(object) || has_task_event?(object) || has_task?(object)
        end

        # Count of tasks in this plan
        def size
            Roby.warn_deprecated "Plan#size is deprecated, use #num_tasks instead"
            @tasks.size
        end

        # Returns true if there is no task in this plan
        def empty?
            @tasks.empty? && @free_events.empty?
        end

        # Iterates on all tasks
        #
        # @yieldparam [Task] task
        def each_task(&block)
            return enum_for(__method__) unless block_given?

            @tasks.each(&block)
        end

        # Returns +object+ if object is a plan object from this plan, or if
        # it has no plan yet (in which case it is added to the plan first).
        # Otherwise, raises ArgumentError.
        #
        # This method is provided for consistency with Transaction#[]
        def [](object, create = true)
            if object.plan == self
                object
            elsif !object.finalized? && object.plan.template?
                add(object)
                object
            elsif object.finalized? && create
                raise ArgumentError,
                      "#{object} is has been finalized, and can't be reused"
            else
                raise ArgumentError, "#{object} is not from #{self}"
            end
        end

        def self.can_gc?(task)
            if task.starting?
                true # wait for the task to be started before deciding ...
            elsif task.running? && !task.finishing?
                task.event(:stop).controlable?
            else
                true
            end
        end

        # @api private
        #
        # Perform sanity checks on a plan object that will be finalized
        def verify_plan_object_finalization_sanity(object)
            unless object.root_object?
                raise ArgumentError, "cannot remove #{object} which is a non-root object"
            end

            return if object.plan == self

            if !object.plan
                if object.removed_at && !object.removed_at.empty?
                    raise ArgumentError,
                          "#{object} has already been removed from its plan\n"\
                          "Removed at\n  #{object.removed_at.join("\n  ")}"
                else
                    raise ArgumentError,
                          "#{object} has already been removed from its plan. "\
                          "Set PlanObject.debug_finalization_place to true to "\
                          "get the backtrace of where (in the code) the object "\
                          "got finalized"
                end
            elsif object.plan.template?
                raise ArgumentError, "#{object} has never been included in this plan"
            else
                raise ArgumentError,
                      "#{object} is not in #{self}: #plan == #{object.plan}"
            end
        end

        def finalize_task(task, timestamp = nil)
            verify_plan_object_finalization_sanity(task)
            if (services = plan_services.delete(task))
                services.each(&:finalized!)
            end

            # Remove relations first. This is needed by transaction since
            # removing relations may need wrapping some new task, and in
            # that case these new task will be discovered as well
            task.clear_relations(remove_internal: true)
            task.mission = false

            task.bound_events.each_value do |ev|
                finalized_event(ev)
            end
            finalized_task(task)

            task.bound_events.each_value do |ev|
                ev.finalized!(timestamp)
            end
            task.finalized!(timestamp)
        end

        def finalize_event(event, timestamp = nil)
            verify_plan_object_finalization_sanity(event)

            # Remove relations first. This is needed by transaction since
            # removing relations may need wrapping some new event, and in
            # that case these new event will be discovered as well
            event.clear_relations
            finalized_event(event)
            event.finalized!(timestamp)
        end

        def remove_task(task, timestamp = Time.now)
            verify_plan_object_finalization_sanity(task)
            remove_task!(task, timestamp)
        end

        def remove_task!(task, timestamp = Time.now)
            @tasks.delete(task)
            @task_index.mission_tasks.delete(task)
            @task_index.permanent_tasks.delete(task)
            @task_index.remove(task)

            task.bound_events.each_value do |ev|
                @task_events.delete(ev)
            end
            finalize_task(task, timestamp)
            self
        end

        def remove_free_event(event, timestamp = Time.now)
            verify_plan_object_finalization_sanity(event)
            remove_free_event!(event, timestamp)
        end

        def remove_free_event!(event, timestamp = Time.now)
            @free_events.delete(event)
            @task_index.permanent_events.delete(event)
            finalize_event(event, timestamp)
            self
        end

        # @deprecated use {#remove_task} or {#remove_free_event} instead
        def remove_object(object, timestamp = Time.now)
            Roby.warn_deprecated(
                "#remove_object is deprecated, use either "\
                "#remove_task or #remove_free_event"
            )

            if has_task?(object)
                remove_task(object, timestamp)
            elsif has_free_event?(object)
                remove_free_event(object, timestamp)
            else
                raise ArgumentError,
                      "#{object} is neither a task nor a free event of #{self}"
            end
        end

        def clear!
            each_task_relation_graph(&:clear)
            each_event_relation_graph(&:clear)
            @free_events.clear
            @tasks.clear
            @task_index.clear
            @task_events.clear
        end

        # Remove all tasks
        def clear
            tasks = @tasks
            @tasks = Set.new
            free_events = @free_events
            @free_events = Set.new

            clear!

            remaining = tasks.find_all do |t|
                if t.running?
                    true
                else
                    finalize_task(t)
                    false
                end
            end

            unless remaining.empty?
                Roby.warn "#{remaining.size} tasks remaining after clearing "\
                          "the plan as they are still running"
                remaining.each do |t|
                    Roby.warn "  #{t}"
                end
            end
            free_events.each do |e|
                finalize_event(e)
            end

            self
        end

        # Hook called when +task+ has been removed from this plan
        def finalized_task(task)
            transactions.each do |trsc|
                next unless trsc.proxying?

                if (proxy = trsc.find_local_object_for_task(task))
                    trsc.finalized_plan_task(proxy)
                end
            end
            log(:finalized_task, droby_id, task)
        end

        # Hook called when +event+ has been removed from this plan
        def finalized_event(event)
            log(:finalized_event, droby_id, event)
            return unless event.root_object?

            transactions.each do |trsc|
                next unless trsc.proxying?

                if (proxy = trsc.find_local_object_for_event(event))
                    trsc.finalized_plan_event(proxy)
                end
            end
        end

        # Replace +task+ with a fresh copy of itself.
        #
        # The new task takes the place of the old one in the plan: any relation
        # that was going to/from +task+ or one of its events is removed, and the
        # corresponding one is created, but this time involving the newly
        # created task.
        def recreate(task)
            new_task = task.create_fresh_copy
            replace_task(task, new_task)
            new_task
        end

        # Creates a new planning pattern replacing the given task and its
        # current planner
        #
        # @param [Roby::Task] task the task that needs to be replanned
        # @return [Roby::Task] the new planning pattern
        def replan(task)
            return task.create_fresh_copy unless task.planning_task

            planner = replan(task.planning_task)
            planned = task.create_fresh_copy
            planned.abstract = true
            planned.planned_by planner
            replace(task, planned)
            planned
        end

        # The set of blocks that should be called to check the structure of the
        # plan.
        #
        # @yieldparam [Plan] the plan
        # @yieldreturn [Array<(#to_execution_exception,Array<Task>)>] a list
        #   of exceptions, and the tasks toward which these exceptions
        #   should be propagated. If the list of tasks is nil, all parents
        #   of the exception's origin will be selected
        attr_reader :structure_checks

        @structure_checks = []
        class << self
            # A set of structure checking procedures that must be performed on all plans
            #
            # @yieldparam [Plan] the plan
            # @yieldreturn [Array<(#to_execution_exception,Array<Task>)>] a list
            #   of exceptions, and the tasks toward which these exceptions
            #   should be propagated. If the list of tasks is nil, all parents
            #   of the exception's origin will be selected
            attr_reader :structure_checks
        end

        # Get all missions that have failed
        def self.check_failed_missions(plan)
            result = []
            plan.mission_tasks.each do |task|
                result << MissionFailedError.new(task) if task.failed?
            end
            plan.permanent_tasks.each do |task|
                result << PermanentTaskError.new(task) if task.failed?
            end
            result
        end
        structure_checks << method(:check_failed_missions)

        # @api private
        #
        # Normalize the value returned by one of the {#structure_checks}, by
        # computing the list of propagation parents if they were not specified
        # in the return value
        #
        # @param [Hash] result
        # @param [Array,Hash] new
        def format_exception_set(result, new)
            [*new].each do |error, tasks|
                roby_exception = error.to_execution_exception
                tasks = [error.parent] if !tasks && error.kind_of?(RelationFailedError)
                result[roby_exception] = tasks
            end
            result
        end

        def call_structure_check_handler(handler)
            handler.call(self)
        end

        # Perform the structure checking step by calling the procs registered
        # in {#structure_checks} and {Plan.structure_checks}
        #
        # @return [Hash<ExecutionException,Array<Roby::Task>,nil>
        def check_structure
            # Do structure checking and gather the raised exceptions
            exceptions = {}
            (Plan.structure_checks + structure_checks).each do |prc|
                new_exceptions = call_structure_check_handler(prc)
                next unless new_exceptions

                format_exception_set(exceptions, new_exceptions)
            end
            exceptions
        end

        # Run a garbage collection pass. This is 'static', as it does not care
        # about the task's state: it will simply remove *from the plan* any task
        # that is not useful *in the context of the plan*.
        #
        # This is mainly useful for static tests, and for transactions
        #
        # Do *not* use it on executed plans.
        def static_garbage_collect(protected_roots: Set.new, &block)
            unneeded = unneeded_tasks(additional_useful_roots: protected_roots)
            if block
                unneeded.each(&block)
            else
                unneeded.each { |t| remove_task(t) }
            end
        end

        # Finds a single difference between this plan and the other plan, using
        # the provided mappings to map objects from self to object in other_plan
        def find_plan_difference(other_plan, mappings)
            all_self_objects  = tasks | free_events | task_events
            all_other_objects = (
                other_plan.tasks | other_plan.free_events | other_plan.task_events
            )

            all_mapped_objects = all_self_objects.map do |obj|
                return [:new_object, obj] unless mappings.key?(obj)

                mappings[obj]
            end.to_set

            if all_mapped_objects != all_other_objects
                return [:removed_objects, all_other_objects - all_mapped_objects]
            elsif mission_tasks.map { |m| mappings[m] }.to_set != other_plan.mission_tasks
                return [:missions_differ]
            elsif permanent_tasks.map { |p| mappings[p] }.to_set != other_plan.permanent_tasks
                return [:permanent_tasks_differ]
            elsif permanent_events.map { |p| mappings[p] }.to_set != other_plan.permanent_events
                return [:permanent_events_differ]
            end

            each_task_relation_graph do |graph|
                other_graph = other_plan.task_relation_graph_for(graph.class)
                if (diff = graph.find_edge_difference(other_graph, mappings))
                    return [graph.class] + diff
                end
            end

            each_event_relation_graph do |graph|
                other_graph = other_plan.event_relation_graph_for(graph.class)
                if (diff = graph.find_edge_difference(other_graph, mappings))
                    return [graph.class] + diff
                end
            end
            nil
        end

        # Compares this plan to +other_plan+, mappings providing the mapping
        # from task/Events in +self+ to task/events in other_plan
        def same_plan?(other_plan, mappings)
            !find_plan_difference(other_plan, mappings)
        end

        # Returns a Query object that applies on this plan.
        #
        # This is equivalent to
        #
        #   Roby::Query.new(self)
        #
        # Additionally, the +model+ and +args+ options are passed to
        # Query#which_fullfills. For example:
        #
        #   plan.find_tasks(Tasks::SimpleTask, id: 20)
        #
        # is equivalent to
        #
        #   Roby::Query.new(self).which_fullfills(Tasks::SimpleTask, id: 20)
        #
        # The returned query is applied on the global scope by default. This
        # means that, if it is applied on a transaction, it will match tasks
        # that are in the underlying plans but not yet in the transaction,
        # import the matches in the transaction and return the new proxies.
        #
        # See #find_local_tasks for a local query.
        def find_tasks(model = nil, args = nil)
            q = Queries::Query.new(self)
            q.which_fullfills(model, args) if model || args
            q
        end

        # Starts a local query on this plan.
        #
        # Unlike #find_tasks, when applied on a transaction, it will only match
        # tasks that are already in the transaction.
        #
        # See #find_global_tasks for a local query.
        def find_local_tasks(*args, &block)
            query = find_tasks(*args, &block)
            query.local_scope
            query
        end

        # @api private
        #
        # Internal delegation from the matchers to the plan object to determine
        # the 'right' query algorithm
        def query_result_set(matcher)
            Queries::PlanQueryResult.from_plan(self, matcher)
        end

        # The list of fault response tables that are currently globally active
        # on this plan
        attr_reader :active_fault_response_tables

        # Enables a fault response table on this plan
        #
        # @param [Model<Coordination::FaultResponseTable>] table_model the fault
        #   response table model
        # @param [Hash] arguments the arguments that should be passed to the
        #   created table
        # @return [Coordination::FaultResponseTable] the fault response table
        #   that got added to this plan. It can be removed using
        #   {#remove_fault_response_table}
        # @return [void]
        # @see remove_fault_response_table
        def use_fault_response_table(table_model, arguments = {})
            table = table_model.new(self, arguments)
            table.attach_to(self)
            active_fault_response_tables << table
            table
        end

        # Remove a fault response table that has been added with
        # {#use_fault_response_table}
        #
        # @overload remove_fault_response_table(table)
        #   @param [Coordination::FaultResponseTable] table the table that
        #     should be removed. This is the return value of
        #     {#use_fault_response_table}
        #
        # @overload remove_fault_response_table(table_model)
        #   Removes all the tables whose model is the given table model
        #
        #   @param [Model<Coordination::FaultResponseTable>] table_model
        #
        # @return [void]
        # @see use_fault_response_table
        def remove_fault_response_table(table_model)
            active_fault_response_tables.delete_if do |t|
                if (table_model.kind_of?(Class) && t.kind_of?(table_model)) || t == table_model
                    t.removed!
                    true
                end
            end
        end

        # Tests whether a task is useful from the point of view of a reference task
        #
        # It is O(N) where N is the number of edges in the combined task
        # relation graphs. If you have to do a lot of tests with the same task,
        # compute the set of useful tasks with {Plan#compute_useful_tasks}
        #
        # @param reference_task the reference task
        # @param task the task whose usefulness is being tested
        # @return [Boolean]
        def in_useful_subplan?(reference_task, tested_task)
            compute_useful_tasks([reference_task]) do |useful_t|
                return true if useful_t == tested_task
            end
            false
        end

        # Enumerate object identities along the transaction stack
        #
        # The enumeration starts with the deepest transaction and stops at the
        # topmost plan where the object is not a transaction proxy.
        #
        # @param [PlanObject] object
        # @yieldparam [PlanObject] object the object's identity at the
        #   given level of the stack. Note that the last element is guaranteed
        #   to not be a transaction proxy.
        def each_object_in_transaction_stack(object)
            return enum_for(__method__, object) unless block_given?

            current_plan = self
            loop do
                yield(current_plan, object)

                return unless object.transaction_proxy?

                current_plan = current_plan.plan
                object = object.__getobj__
            end
            # Never reached
        end
    end
end
