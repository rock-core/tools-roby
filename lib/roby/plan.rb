module Roby
    # A plan object manages a collection of tasks and events.
    #
    # == Adding and removing objects from plans
    # The #add, #add_mission and #add_permanent calls allow to add objects in
    # plans. The #remove_object removes the same objects from the plan. Note
    # that you should never remove objects yourself: a GC mechanism will do
    # that properly for you, taking into account the consequences of the object
    # removal.
    #
    # To reduce the complexity of object management, a garbage collection
    # mechanism is in place during the plan execution, stopping and removing
    # tasks that are not useful anymore for the system's goals. This garbage
    # collection mechanism runs at the end of the execution cycle. Once an
    # object is not active (i.e. for a task, once it is stopped), the object is
    # /finalized/ and either the #finalized_task or the #finalized_event hook is
    # called.
    #
    # Two special kinds of objects exist in plans:
    # * the +missions+ (#missions, #mission?, #add_mission and #unmark_mission) are the
    #   final goals of the system.  A task is +useful+ if it helps into the
    #   Realization of a mission (it is the child of a mission through one of the
    #   task relations).
    # * the +permanent+ objects (#add_permanent, #unmark_permanent, #permanent?, #permanent_tasks and
    #   #permanent_events) are plan objects that are not affected by the plan's
    #   garbage collection mechanism. As for missions, task that are useful to
    #   permanent tasks are also 
    #
    class Plan < DistributedObject
	extend Logger::Hierarchy
	extend Logger::Forward

	# The task index for this plan. This is a {Queries::Index} object which allows
        # efficient resolving of queries.
	attr_reader :task_index

	# The list of tasks that are included in this plan
	attr_reader :known_tasks
	# The set of events that are defined by #known_tasks
	attr_reader :task_events
        # The list of the robot's missions. Do not change that set directly, use
        # #add_mission and #remove_mission instead.
	attr_reader :missions
	# The list of tasks that are kept outside GC. Do not change that set
        # directly, use #permanent and #auto instead.
	attr_reader :permanent_tasks
	# The list of events that are not included in a task
	attr_reader :free_events
	# The list of events that are kept outside GC. Do not change that set
        # directly, use #permanent and #auto instead.
	attr_reader :permanent_events
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
	    else super
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
        def template?; false end

	# Check that this is an executable plan. This is always true for
	# plain Plan objects and false for transcations
	def executable?; false end

	def initialize(graph_observer: nil)
	    @missions	 = Set.new
	    @permanent_tasks  = Set.new
	    @permanent_events = Set.new
	    @known_tasks = Set.new
	    @free_events = Set.new
	    @task_events = Set.new
	    @transactions = Set.new
            @fault_response_tables = Array.new
            @triggers = []

            @plan_services = Hash.new

            @task_relation_graphs  = Relations::Space.new_relation_graph_mapping
            Task.all_relation_spaces.each do |space|
                task_relation_graphs.merge!(
                    space.instanciate(observer: graph_observer))
            end

            @event_relation_graphs = Relations::Space.new_relation_graph_mapping
            EventGenerator.all_relation_spaces.each do |space|
                event_relation_graphs.merge!(
                    space.instanciate(observer: graph_observer))
            end

            @active_fault_response_tables = Array.new

            @structure_checks = Array.new
            each_relation_graph do |graph|
                if graph.respond_to?(:check_structure)
                    structure_checks << graph.method(:check_structure)
                end
            end

	    @task_index  = Roby::Queries::Index.new

	    super() if defined? super
	end

        # The graphs that make task relations, formatted as required by
        # {Relations::DirectedRelationSupport#relation_graphs}
        #
        # @see each_task_relation_graph
        attr_reader :task_relation_graphs

        # The graphs that make event relations, formatted as required by
        # {Relations::DirectedRelationSupport#relation_graphs}
        #
        # @see each_event_relation_graph
        attr_reader :event_relation_graphs

        # Enumerate the graph objects that contain this plan's relation
        # information
        #
        # @yieldparam [Relations::Graph] graph
        def each_relation_graph(&block)
            return enum_for(__method__) if !block_given?
            each_event_relation_graph(&block)
            each_task_relation_graph(&block)
        end

        # Enumerate the graph objects that contain this plan's event relation
        # information
        #
        # @yieldparam [Relations::EventRelationGraph] graph
        def each_event_relation_graph
            return enum_for(__method__) if !block_given?
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
            return enum_for(__method__) if !block_given?
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
	    "#<#{to_s}: missions=#{missions.to_s} tasks=#{known_tasks.to_s} events=#{free_events.to_s} transactions=#{transactions.to_s}>"
	end

        # Calls the given block in the execution thread of this plan's engine.
        # If there is no engine attached to this plan, yields immediately
        #
        # See ExecutionEngine#execute
        def execute(&block)
            yield
        end

        # @deprecated use {#merge} instead
        def copy_to(copy)
            copy.merge(self)
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

            merging_plan(plan)

            free_events.merge(plan.free_events)
            missions.merge(plan.missions)
            known_tasks.merge(plan.known_tasks)
            permanent_tasks.merge(plan.permanent_tasks)
            permanent_events.merge(plan.permanent_events)
            task_index.merge(plan.task_index)
            task_events.merge(plan.task_events)

            # Now merge the relation graphs
            #
            # Since task_relation_graphs contains both Class<Graph>=>Graph and
            # Graph=>Graph, we merge only the graphs for which
            # self.task_relation_graphs has an entry (i.e. Class<Graph>) and
            # ignore the rest
            plan.task_relation_graphs.each do |rel_id, rel|
                next if rel_id == rel
                next if !(this_rel = task_relation_graphs.fetch(rel_id, nil))
                this_rel.merge(rel)
            end
            plan.event_relation_graphs.each do |rel_id, rel|
                next if rel_id == rel
                next if !(this_rel = event_relation_graphs.fetch(rel_id, nil))
                this_rel.merge(rel)
            end

            merged_plan(plan)
        end

        # Moves the content of other_plan into self, and clears other_plan
        #
        # It is assumed that other_plan and plan do not intersect
        #
        # Unlike {#merge}, it ensures that all plan objects have their {#plan}
        # attribute properly updated, and it cleans plan
        #
        # @param [Roby::Plan] plan the plan to merge into self
        def merge!(plan)
            return if plan == self

            merge(plan)

            # Note: Task#plan= updates its bound events
            tasks, events = plan.known_tasks.dup, plan.free_events.dup
            plan.clear!
            tasks.each { |t| t.plan = self }
            events.each { |e| e.plan = self }
        end

        # Hook called just before performing a {#merge}
        def merging_plan(plan)
        end

        # Hook called when a {#merge} has been performed
        def merged_plan(plan)
        end

        def deep_copy
            plan = Roby::Plan.new
            mappings = deep_copy_to(plan)
            return plan, mappings
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
            mappings = Hash.new do |h, k|
                if !self.include?(k)
                    raise InternalError, "#{k} is listed in a relation, but is not included in the corresponding plan #{self}"
                else
                    raise InternalError, "#{k} is an object in #{self} for which no mapping has been created in #{copy}"
                end
            end

            # First create a copy of all the tasks
            known_tasks.each do |t|
                new_t = t.dup
                mappings[t] = new_t

                t.each_event do |ev|
                    mappings[ev] = new_t.event(ev.symbol)
                end
                copy.add(new_t)
            end
            free_events.each do |e|
                new_e = e.dup
                mappings[e] = new_e
                copy.add(new_e)
            end

            missions.each { |t| copy.add_mission(mappings[t]) }
            permanent_tasks.each { |t| copy.add_permanent(mappings[t]) }
            permanent_events.each { |e| copy.add_permanent(mappings[e]) }

            copy_relation_graphs_to(copy, mappings)
            mappings
        end

        def copy_relation_graphs_to(copy, mappings)
            each_task_relation_graph do |graph|
                target_graph = copy.task_relation_graph_for(graph.class)
                graph.each_edge do |parent, child|
                    target_graph.add_edge(
                        mappings[parent], mappings[child], graph.edge_info(parent, child))
                end
            end

            each_event_relation_graph do |graph|
                target_graph = copy.event_relation_graph_for(graph.class)
                graph.each_edge do |parent, child|
                    target_graph.add_edge(
                        mappings[parent], mappings[child], graph.edge_info(parent, child))
                end
            end
        end

        # @api private
        #
        # Normalize an validate the arguments to {#add} into a list of plan objects
	def normalize_add_arguments(objects)
            if !objects.respond_to?(:each)
                objects = [objects]
            end

	    objects.map do |o|
                if o.respond_to?(:as_plan) then o.as_plan
                elsif o.respond_to?(:to_event) then o.to_event
                elsif o.respond_to?(:to_task) then o.to_task
		else raise ArgumentError, "found #{o || 'nil'} which is neither a task nor an event"
		end
	    end
	end

	# If this plan is a toplevel plan, returns self. If it is a
	# transaction, returns the underlying plan
	def real_plan
	    ret = self
	    while ret.respond_to?(:plan)
		ret = ret.plan
	    end
	    ret
	end

        # True if this plan is root in the plan hierarchy
        def root_plan?
            !respond_to?(:plan)
        end

        # Returns the set of stacked transaction
        #
        # @return [Array] the list of plans in the transaction stack, the first
        #   element being the most-nested transaction and the last element the
        #   underlying real plan (equal to {#real_plan})
        def transaction_stack
            plan_chain = [self]
            while plan_chain.last.respond_to?(:plan)
                plan_chain << plan_chain.last.plan
            end
            plan_chain
        end

	# Inserts a new mission in the plan.
        #
        # In the plan manager, missions are the tasks which constitute the
        # robot's goal. This is the base for two things:
        # * if a mission fails, the MissionFailedError is raised
        # * the mission and all the tasks and events which are useful for it,
        #   are not removed automatically by the garbage collection mechanism.
        #   A task or event is <b>useful</b> if it is part of the child subgraph
        #   of the mission, i.e. if there is a path in the relation graphs where
        #   the mission is the source and the task is the target.
        def add_mission(task)
            if task.respond_to?(:as_plan)
                task = task.as_plan
            end
	    return if @missions.include?(task)
	    add(task)
            add_mission_task(task)
	    self
	end
	# Hook called when +tasks+ have been inserted in this plan
	def added_mission(tasks)
            super if defined? super 
        end
	# Checks if +task+ is a mission of this plan
	def mission?(task); @missions.include?(task.to_task) end

	# Removes the task in +tasks+ from the list of missions
	def unmark_mission(task)
            task = task.to_task
            return if !@missions.include?(task)
	    @missions.delete(task)
	    task.mission = false if task.self_owned?

	    unmarked_mission(task)
            notify_plan_status_change(task, :normal)
	    self
	end

	# Hook called when +tasks+ have been discarded from this plan
	def unmarked_mission(task)
            super if defined? super
        end

	# Adds +object+ in the list of permanent tasks. Permanent tasks are
        # tasks that are not to be subject to the plan's garbage collection
        # mechanism (i.e. they will not be removed even though they are not
        # directly linked to a mission).
        #
        # #object is at the same time added in the plan, meaning that all the
        # tasks and events related to it are added in the plan as well. See
        # #add.
        #
        # Unlike missions, the failure of a permanent task does not constitute
        # an error.
        #
        # See also #unmark_permanent and #permanent?
	def add_permanent(object)
            if object.respond_to?(:as_plan)
                object = object.as_plan
            end

            if object.respond_to?(:to_task)
                task = object.to_task
                add(task)
                add_permanent_task(task)
            else
                add_permanent_event(object)
                add(object)
            end
            self
	end

	# Removes +object+ from the list of permanent objects. Permanent objects
        # are protected from the plan's garbage collection. This does not remove
        # the task/event itself from the plan.
        #
        # See also #add_permanent and #permanent?
	def unmark_permanent(object)
            if object.respond_to?(:to_task)
                object = object.to_task
                if @permanent_tasks.include?(object)
                    @permanent_tasks.delete(object)
                    notify_plan_status_change(object, :normal)
                end
            elsif object.respond_to?(:to_event)
                @permanent_events.delete(object.to_event)
            else
                raise ArgumentError, "expected a task or event and got #{object}"
            end
        end

        # True if +obj+ is neither a permanent task nor a permanent object.
        #
        # See also #add_permanent and #unmark_permanent
	def permanent?(object)
            if object.respond_to?(:to_task)
                @permanent_tasks.include?(object.to_task) 
            elsif object.respond_to?(:to_event)
                @permanent_events.include?(object.to_event)
            else
                raise ArgumentError, "expected a task or event and got #{object}"
            end
        end

        # Perform notifications related to the status change of a task
        def notify_plan_status_change(task, status)
            if services = plan_services[task]
                services.each { |s| s.notify_plan_status_change(status) }
            end
        end

	def edit
	    if block_given?
                yield
	    end
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
            if from.plan != self
                raise ArgumentError, "trying to replace #{from} but its plan is #{from.plan}, expected #{self}"
            elsif to.plan.template?
                add(to)
            elsif to.plan != self
                raise ArgumentError, "trying to replace #{to} but its plan is #{to.plan}, expected #{self}"
            elsif from == to
                return 
            end

	    # Swap the subplans of +from+ and +to+
	    yield(from, to)

	    if mission?(from)
		add_mission(to)
                replaced(from, to)
		unmark_mission(from)
	    elsif permanent?(from)
		add_permanent(to)
                replaced(from, to)
		unmark_permanent(from)
	    else
		add(to)
                replaced(from, to)
	    end
        end

	def handle_replace(from, to) # :nodoc:
            handle_force_replace(from, to) do
                # Check that +to+ is valid in all hierarchy relations where +from+ is a child
                if !to.fullfills?(*from.fullfilled_model)
                    models = from.fullfilled_model.first
                    missing = models.find_all do |m|
                        !to.fullfills?(m)
                    end
                    if missing.empty?
                        raise InvalidReplace.new(from, to), "argument mismatch from #{from.fullfilled_model.last} to #{to.arguments}"
                    else
                        raise InvalidReplace.new(from, to), "missing provided models #{missing.map(&:name).join(", ")}"
                    end
                end

                # Swap the subplans of +from+ and +to+
                yield(from, to)
            end
	end

        # Replace the task +from+ by +to+ in all relations +from+ is part of
        # (including events).
        #
        # See also #replace
	def replace_task(from, to)
	    handle_replace(from, to) do
		from.replace_by(to)
	    end
	end

        # Replace +from+ by +to+ in the plan, in all relations in which +from+
        # and its events are /children/. It therefore replaces the subplan
        # generated by +from+ (i.e. +from+ and all the tasks/events that can be
        # reached by following the task and event relations) by the subplan
        # generated by +to+.
        #
        # See also #replace_task
	def replace(from, to)
	    handle_replace(from, to) do
		from.replace_subplan_by(to)
	    end
	end

        # Register a new plan service on this plan
        def add_plan_service(service)
            if service.task.plan != self
                raise "trying to register a plan service on #{self} for #{service.task}, which is included in #{service.task.plan}"
            end

            set = (plan_services[service.task] ||= Set.new)
            if !set.include?(service)
                set << service
            end
            self
        end

        # Deregisters a plan service from this plan
        def remove_plan_service(service)
            if set = plan_services[service.task]
                set.delete(service)
                if set.empty?
                    plan_services.delete(service.task)
                end
            end
        end

        # Change the actual task a given plan service is representing
        def move_plan_service(service, new_task)
            return if new_task == service.task

            remove_plan_service(service)
            service.task = new_task
            add_plan_service(service)
        end

        # If at least one plan service is defined for +task+, returns one of
        # them. Otherwise, returns nil.
        def find_plan_service(task)
            if set = plan_services[task]
                set.find { true }
            end
        end

        # Replace a subplan
        def replace_subplan(task_mappings, event_mappings, task_children: true, event_children: true)
            new_relations, removed_relations =
                compute_subplan_replacement(task_mappings, each_task_relation_graph,
                                            child_objects: task_children)
            apply_replacement_operations(new_relations, removed_relations)

            new_relations, removed_relations =
                compute_subplan_replacement(event_mappings, each_event_relation_graph,
                                            child_objects: event_children)
            apply_replacement_operations(new_relations, removed_relations)
        end

        def compute_subplan_replacement(mappings, relation_graphs, child_objects: true)
            new_relations, removed_relations = Array.new, Array.new
            relation_graphs.each do |graph|
                next if graph.strong?

                mappings.each do |obj, mapped_obj|
                    obj.each_parent_object(graph) do |parent|
                        next if mappings.has_key?(parent)
                        if !graph.copy_on_replace?
                            removed_relations << [graph, parent, obj]
                        end
                        if mapped_obj
                            new_relations << [graph, parent, mapped_obj, parent[obj, graph]]
                        end
                    end

                    next if !child_objects
                    obj.each_child_object(graph) do |child, info|
                        next if mappings.has_key?(child)
                        if !graph.copy_on_replace?
                            removed_relations << [graph, obj, child]
                        end
                        if mapped_obj
                            new_relations << [graph, mapped_obj, child, obj[child, graph]]
                        end
                    end
                end
            end
            return new_relations, removed_relations
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
            if services = plan_services.delete(replaced_task)
                services.each do |srv|
                    srv.task = replacing_task
                    (plan_services[replacing_task] ||= Set.new) << srv
                end
            end
            super if defined? super
        end

        def add_mission_task(task)
	    return if missions.include?(task)
            add([task])

	    missions << task
	    task.mission = true if task.self_owned?
	    added_mission(task)
            notify_plan_status_change(task, :mission)
	    true
        end

        def add_permanent_task(task)
            return if permanent_tasks.include?(task)
            add([task])

            permanent_tasks << task
            notify_plan_status_change(task, :permanent)
            true
        end

        def add_permanent_event(event)
            return if permanent_events.include?(event)
            add([event])
            permanent_events << event
            true
        end

        # @api private
        #
        # Registers a task object in this plan
        #
        # It is for Roby internal usage only, for the creation of template
        # plans. Use {#add}.
        def register_task(task)
            known_tasks << task
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
        # that are reachable through any relations). The #added_events and
        # #added_tasks hooks are called for the objects that were not in
        # the plan.
	def add(objects)
	    objects = normalize_add_arguments(objects)

            plans = Set.new
            objects.each do |plan_object|
                p = plan_object.plan
                next if p == self
                if plan_object.removed_at
                    raise ArgumentError, "cannot add #{plan_object} in #{self}, it has been removed from the plan"
                elsif !p
                    raise InternalError, "there seem to be an inconsistency, #{plan_object}#plan is nil but #removed_at is not set"
                elsif p.empty?
                    raise InternalError, "there seem to be an inconsistency, #{plan_object} is associated with #{p} but #{p} is empty"
                elsif !p.template?
                    raise ModelViolation, "cannot add #{plan_object} in #{self}, it is already included in #{p}"
                end
                plans << p
            end

            triggered = Array.new
            plans.each do |p|
                triggered = p.known_tasks.map do |t|
                    [t, triggers.find_all { |trigger| trigger === t }]
                end
                merge!(p)
                triggered.each do |task, triggers|
                    triggers.each { |trigger| trigger.call(task) }
                end
            end

	    self
	end

        Trigger = Struct.new :query_object, :block do
            def ===(task)
                query_object === task
            end
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
            known_tasks.each do |t|
                if tr === t
                    tr.call(t)
                end
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

	# Hook called when new tasks have been discovered in this plan
        def added_tasks(tasks)
            raise NotImplementedError, "the #added_tasks hook has been superseded by #merged_plan"
        end

	# Hook called when new events have been discovered in this plan
	def added_events(events)
            raise NotImplementedError, "the #added_events hook has been superseded by #merged_plan"
	end

        # Creates a new transaction and yields it. Ensures that the transaction
        # is discarded if the block returns without having committed it.
        def in_transaction
            yield(trsc = Transaction.new(self))

        ensure
            if trsc && !trsc.finalized?
                trsc.discard_transaction
            end
        end
	# Hook called when a new transaction has been built on top of this plan
	def added_transaction(trsc); super if defined? super end
	# Removes the transaction +trsc+ from the list of known transactions
	# built on this plan
	def remove_transaction(trsc)
	    transactions.delete(trsc)
	    removed_transaction(trsc)
	end
	# Hook called when a new transaction has been built on top of this plan
	def removed_transaction(trsc); super if defined? super end

        # @api private
        #
        # Compute the subplan that is useful for a given set of tasks
        #
        # @param [Set<Roby::Task>
	def compute_useful_tasks(seeds)
            seeds = seeds.to_set
            graphs = each_task_relation_graph.
                find_all { |g| g.root_relation? && !g.weak? }

            visitors = graphs.map do |g|
                [g, RGL::DFSVisitor.new(g), seeds.dup]
            end

            result = seeds.dup

            has_pending_seeds = true
            while has_pending_seeds
                has_pending_seeds = false
                visitors.each do |graph, visitor, seeds|
                    next if seeds.empty?

                    new_seeds = Array.new
                    seeds.each do |vertex|
                        if !visitor.finished_vertex?(vertex) && graph.has_vertex?(vertex)
                            graph.depth_first_visit(vertex, visitor) { |v| new_seeds << v }
                        end
                    end
                    if !new_seeds.empty?
                        has_pending_seeds = true
                        result.merge(new_seeds)
                        visitors.each { |g, _, s| s.merge(new_seeds) if g != graph }
                    end
                    seeds.clear
                end
            end

            result
	end

        def locally_useful_roots
	    # Create the set of tasks which must be kept as-is
	    seeds = @missions | @permanent_tasks
	    for trsc in transactions
		seeds.merge trsc.proxy_objects.keys.to_set
	    end
            seeds
        end

        def remotely_useful_roots
            Distributed.remotely_useful_objects(remote_tasks, true, nil).to_set
        end

	def locally_useful_tasks
	    compute_useful_tasks(locally_useful_roots)
	end

        def remotely_useful_tasks
	    compute_useful_tasks(remotely_useful_roots)
        end

        def useful_tasks
            compute_useful_tasks(locally_useful_roots | remotely_useful_roots)
        end

	def unneeded_tasks
	    known_tasks - useful_tasks
	end

	def local_tasks
	    task_index.by_owner[Roby::Distributed] || Set.new
	end

	def remote_tasks
	    if local_tasks = task_index.by_owner[Roby::Distributed]
		known_tasks - local_tasks
	    else
		known_tasks
	    end
	end

	# Computes the set of useful tasks and checks that +task+ is in it.
	# This is quite slow. It is here for debugging purposes. Do not use it
	# in production code
	def useful_task?(task)
	    known_tasks.include?(task) && !unneeded_tasks.include?(task)
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

            def handle_examine_edge(u, v)
                if task_events.include?(v) || useful_free_events.include?(v)
                    color_map[v] = :BLACK
                    @useful = true
                end
            end

            def follow_edge?(u, v)
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
        # @param [Set<EventGenerator>] useful_events  the set of useful events (free or task) computed so far
        # @param [Set<EventGenerator>] useless_events the remainder of {#free_events} that
        #   is not included in useful_events yet
        # @return [Set<EventGenerator>]
        def compute_useful_free_events
            # Quick path for a very common case
            return Set.new if free_events.empty?

            graphs = each_event_relation_graph.
                find_all { |g| g.root_relation? && !g.weak? }

            seen = Set.new
            result = permanent_events.dup
            pending_events = free_events.to_a
            while !pending_events.empty?
                # This basically computes the subplan that contains "seed" and
                # determines if it is useful or not
                seed = pending_events.shift
                next if seen.include?(seed)

                visitors = Array.new
                graphs.each do |g|
                    visitors << [g, UsefulFreeEventVisitor.new(g, task_events, permanent_events), [seed].to_set]
                    visitors << [g.reverse, UsefulFreeEventVisitor.new(g.reverse, task_events, permanent_events), [seed].to_set]
                end

                component = [seed].to_set
                has_pending_seeds = true
                while has_pending_seeds
                    has_pending_seeds = false
                    visitors.each do |graph, visitor, seeds|
                        next if seeds.empty?

                        new_seeds = Array.new
                        seeds.each do |vertex|
                            if !visitor.finished_vertex?(vertex) && graph.has_vertex?(vertex)
                                graph.depth_first_visit(vertex, visitor) { |v| new_seeds << v }
                            end
                        end
                        if !new_seeds.empty?
                            has_pending_seeds = true
                            component.merge(new_seeds)
                            visitors.each { |g, _, s| s.merge(new_seeds) if g != graph }
                        end
                        seeds.clear
                    end
                end
                seen.merge(component)
                if visitors.any? { |_, v, _| v.useful? }
                    result.merge(component)
                end
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
		transactions.any? { |trsc| trsc.wrap(ev, false) }
	    end
	    result
	end

	# Checks if +task+ is included in this plan
	def include?(object); @known_tasks.include?(object) || @free_events.include?(object) end
	# Count of tasks in this plan
	def size; @known_tasks.size end
	# Returns true if there is no task in this plan
        def empty?; @known_tasks.empty? && @free_events.empty? end
	# Iterates on all tasks
        #
        # @yieldparam [Task] task
	def each_task
            return enum_for(__method__) if !block_given?
            @known_tasks.each { |t| yield(t) }
        end
 
	# Returns +object+ if object is a plan object from this plan, or if
	# it has no plan yet (in which case it is added to the plan first).
	# Otherwise, raises ArgumentError.
	#
	# This method is provided for consistency with Transaction#[]
	def [](object, create = true)
            if !object.finalized? && object.plan.template?
		add(object)
            elsif object.finalized? && create
		raise ArgumentError, "#{object} is has been finalized, and can't be reused"
	    elsif object.plan != self
		raise ArgumentError, "#{object} is not from #{self}"
	    end
	    object
	end

	def self.can_gc?(task)
	    if task.starting? then true # wait for the task to be started before deciding ...
	    elsif task.running? && !task.finishing?
		task.event(:stop).controlable?
	    else true
	    end
	end

        def discard_modifications(object)
            remove_object(object)
        end

        def finalize_object(object, timestamp = nil)
	    if !object.root_object?
		raise ArgumentError, "cannot remove #{object} which is a non-root object"
	    elsif object.plan != self
		if known_tasks.include?(object) || free_events.include?(object)
		    raise ArgumentError, "#{object} is included in #{self} but #plan == #{object.plan}"
		elsif !object.plan
                    if object.removed_at
                        if PlanObject.debug_finalization_place?
                            raise ArgumentError, "#{object} has already been removed from its plan\n" +
                                "Removed at\n  #{object.removed_at.join("\n  ")}"
                        else
                            raise ArgumentError, "#{object} has already been removed from its plan. Set PlanObject.debug_finalization_place to true to get the backtrace of where (in the code) the object got finalized"
                        end
                    else
			raise ArgumentError, "#{object} has never been included in this plan"
		    end
		end
		raise ArgumentError, "#{object} is not in #{self}: #plan == #{object.plan}"
	    end

            if services = plan_services.delete(object)
                services.each(&:finalized!)
            end

	    # Remove relations first. This is needed by transaction since
	    # removing relations may need wrapping some new objects, and in
	    # that case these new objects will be discovered as well
	    object.clear_relations

            if object.respond_to? :mission=
                object.mission = false
            end

	    case object
	    when EventGenerator
		finalized_event(object)

	    when Task
		for ev in object.bound_events
		    finalized_event(ev[1])
		end
		finalized_task(object)

	    else
		raise ArgumentError, "unknown object type #{object}"
	    end

            object.each_plan_child do |child|
                child.finalized!(timestamp)
            end
            object.finalized!(timestamp)
        end

        # Remove +object+ from this plan. You usually don't have to do that
        # manually. Object removal is handled by the plan's garbage collection
        # mechanism.
	def remove_object(object, timestamp = nil)
	    @free_events.delete(object)
	    @missions.delete(object)
	    @known_tasks.delete(object)
	    @permanent_tasks.delete(object)
	    @permanent_events.delete(object)
            @task_index.remove(object)
            
            case object
            when Task
                for ev in object.bound_events
		    @task_events.delete(ev[1])
                end
            end

            finalize_object(object, timestamp)

	    self
	end

        def clear!
            each_task_relation_graph do |g|
                g.clear
            end
            each_event_relation_graph do |g|
                g.clear
            end
	    @free_events.clear
	    @missions.clear
	    @known_tasks.clear
	    @permanent_tasks.clear
	    @permanent_events.clear
            @task_index.clear
            @task_events.clear
        end

	# Remove all tasks
	def clear
	    known_tasks, @known_tasks = @known_tasks, Set.new
	    free_events, @free_events = @free_events, Set.new

            clear!

            remaining = known_tasks.find_all do |t|
                if executable? && t.running?
                    true
                else
                    finalize_object(t)
                    false
                end
            end
            if !remaining.empty?
                Roby.warn "#{remaining.size} tasks remaining after clearing the plan as they are still running"
                remaining.each do |t|
                    Roby.warn "  #{t}"
                end
            end
	    free_events.each do |e|
                finalize_object(e)
            end

            self
	end

	# backward compatibility
	def finalized(task) # :nodoc:
	    super if defined? super
	end

	# Hook called when +task+ has been removed from this plan
	def finalized_task(task)
            finalized_transaction_object(task) { |trsc, proxy| trsc.finalized_plan_task(proxy) }
	    super if defined? super
	    finalized(task)
	end

	# Hook called when +event+ has been removed from this plan
	def finalized_event(event)
            finalized_transaction_object(event) { |trsc, proxy| trsc.finalized_plan_event(proxy) }
            super if defined? super 
        end

        # Generic filter which checks if +object+ is included in one of the
        # transactions of this plan. If it is the case, it yields the
        # transaction and the associated proxy
        def finalized_transaction_object(object) 
            return unless object.root_object?
            for trsc in transactions
                next unless trsc.proxying?

                if proxy = trsc.wrap(object, false)
                    yield(trsc, proxy)
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
            if !task.planning_task
                return task.create_fresh_copy
            end

            planner = replan(old_planner = task.planning_task)
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

        @structure_checks = Array.new
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
            result = Array.new
            for task in plan.missions
                result << MissionFailedError.new(task) if task.failed?
            end
            for task in plan.permanent_tasks
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
                if !tasks
                    if error.kind_of?(RelationFailedError)
                        tasks = [error.parent]
                    end
                end
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
            exceptions = Hash.new
	    for prc in (Plan.structure_checks + structure_checks)
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
        def static_garbage_collect
            if block_given?
                for t in unneeded_tasks
                    yield(t)
                end
            else
                for t in unneeded_tasks
                    remove_object(t)
                end
            end
        end

        # Finds a single difference between this plan and the other plan, using
        # the provided mappings to map objects from self to object in other_plan
        def find_plan_difference(other_plan, mappings)
            all_self_objects  = known_tasks | free_events | task_events
            all_other_objects = (other_plan.known_tasks | other_plan.free_events | other_plan.task_events)

            all_mapped_objects = all_self_objects.map do |obj|
                if !mappings.has_key?(obj)
                    return [:new_object, obj]
                end
                mappings[obj]
            end.to_set

            if all_mapped_objects != all_other_objects
                return [:removed_objects, all_other_objects - all_mapped_objects]
            elsif missions.map { |m| mappings[m] }.to_set != other_plan.missions
                return [:missions_differ]
            elsif permanent_tasks.map { |p| mappings[p] }.to_set != other_plan.permanent_tasks
                return [:permanent_tasks_differ]
            elsif permanent_events.map { |p| mappings[p] }.to_set != other_plan.permanent_events
                return [:permanent_events_differ]
            end

            each_task_relation_graph do |graph|
                other_graph = other_plan.task_relation_graph_for(graph.class)
                if diff = graph.find_edge_difference(other_graph, mappings)
                    return [graph.class] + diff
                end
            end

            each_event_relation_graph do |graph|
                other_graph = other_plan.event_relation_graph_for(graph.class)
                if diff = graph.find_edge_difference(other_graph, mappings)
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
	    if model || args
		q.which_fullfills(model, args)
	    end
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

	# Called by TaskMatcher#result_set and Query#result_set to get the set
	# of tasks matching +matcher+
	def query_result_set(matcher) # :nodoc:
            filtered = matcher.filter(known_tasks.dup, task_index)

            if matcher.indexed_query?
                filtered
            else
                result = Set.new
                for task in filtered
                    result << task if matcher === task
                end
                result
            end
	end

	# Called by TaskMatcher#each and Query#each to return the result of
	# this query on +self+
	def query_each(result_set, &block) # :nodoc:
	    for task in result_set
		yield(task)
	    end
	end

        def root_in_query?(result_set, task, graph)
            graph.depth_first_visit(task) do |v|
                return false if v != task && result_set.include?(v)
            end
            true
        end

	# Given the result set of +query+, returns the subset of tasks which
	# have no parent in +query+
	def query_roots(result_set, relation) # :nodoc:
            graph = task_relation_graph_for(relation).reverse
            result_set.find_all do |task|
                root_in_query?(result_set, task, graph)
	    end
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
        def use_fault_response_table(table_model, arguments = Hash.new)
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
    end
end

