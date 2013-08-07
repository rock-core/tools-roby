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
    class Plan < BasicObject
	extend Logger::Hierarchy
	extend Logger::Forward

        # The ExecutionEngine object which handles this plan. The role of this
        # object is to provide the event propagation, error propagation and
        # garbage collection mechanisms for the execution.
        attr_accessor :engine
        # The DecisionControl object which is associated with this plan. This
        # object's role is to handle the conflicts that can occur during event
        # propagation.
        def control; engine.control end

	# The task index for this plan. This is a TaskIndex object which allows
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
        # See {add_trigger}
        attr_reader :triggers

	# A set of tasks which are useful (and as such would not been garbage
	# collected), but we want to GC anyway
	attr_reader :force_gc

	# A set of task for which GC should not be attempted, either because
	# they are not interruptible or because their start or stop command
	# failed
	attr_reader :gc_quarantine

        # Put the given task in quarantine. In practice, it means that all the
        # event relations of that task's events are removed, as well as its
        # children. Then, the task is added to gc_quarantine (the task will not
        # be GCed anymore).
        #
        # This is used as a last resort, when the task cannot be stopped/GCed by
        # normal means.
        def quarantine(task)
            task.each_event do |ev|
                ev.clear_relations
            end
            for rel in task.sorted_relations
                next if rel == Roby::TaskStructure::ExecutionAgent
                for child in task.child_objects(rel).to_a
                    task.remove_child_object(child, rel)
                end
            end
            Roby::ExecutionEngine.warn "putting #{task} in quarantine"
            gc_quarantine << task
            self
        end

	# The set of transactions which are built on top of this plan
	attr_reader :transactions

	# If this object is the main plan, checks if we are subscribed to
	# the whole remote plan
	def sibling_on?(peer)
	    if Roby.plan == self then peer.remote_plan
	    else super
	    end
	end

        # The set of relations available for this plan
        attr_reader :relations
        # The propagation engine for this object. It is either nil (if no
        # propagation engine is available) or self.
        attr_reader :propagation_engine
        # The set of PlanService instances that are defined on this plan
        attr_reader :plan_services
        # The list of fault response tables that are currently globally active
        # on this plan
        attr_reader :active_fault_response_tables

	def initialize
	    @missions	 = ValueSet.new
	    @permanent_tasks   = ValueSet.new
	    @permanent_events   = ValueSet.new
	    @known_tasks = ValueSet.new
	    @free_events = ValueSet.new
	    @task_events = ValueSet.new
	    @force_gc    = ValueSet.new
	    @gc_quarantine = ValueSet.new
	    @transactions = ValueSet.new
            @exception_handlers = Array.new
            @fault_response_tables = Array.new
            @active_fault_response_tables = Array.new
            @triggers = []

            on_exception LocalizedError do |plan, error|
                plan.default_localized_error_handling(error)
            end

            @plan_services = Hash.new

            @relations = TaskStructure.relations + EventStructure.relations
            @structure_checks = relations.
                map { |r| r.method(:check_structure) if r.respond_to?(:check_structure) }.
                compact

	    @task_index  = Roby::Queries::Index.new

	    super() if defined? super
	end

        def default_localized_error_handling(error)
            matching_handlers = Array.new
            active_fault_response_tables.each do |table|
                table.find_all_matching_handlers(error).each do |handler|
                    matching_handlers << [table, handler]
                end
            end
            handlers = matching_handlers.sort_by { |_, handler| handler.priority }

            table, handler = handlers.first
            if handler
                handler.activate(error, table.arguments)
            else
                error.each_involved_task.
                    find_all { |t| mission?(t) && t != error.origin }.
                    each do |m|
                        add_error(MissionFailedError.new(m, error.exception))
                    end

                error.each_involved_task.
                    find_all { |t| permanent?(t) && t != error.origin }.
                    each do |m|
                        add_error(PermanentTaskError.new(m, error.exception))
                    end

                pass_exception
            end
        end

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
                    true
                end
            end
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
            if engine
                engine.execute(&block)
            else
                yield
            end
        end

        # Shallow copy of this plan's state (lists of tasks / events and their
        # relations, but not copying the tasks themselves)
        def copy_to(copy)
            known_tasks.each { |t| copy.known_tasks << t }
            free_events.each { |e| copy.free_events << e }
            copy.instance_variable_set :@task_index, task_index.dup

            missions.each { |t| copy.missions << t }
            permanent_tasks.each  { |t| copy.permanent_tasks << t }
            permanent_events.each { |e| copy.permanent_events << e }
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

            # We now have to copy the relations
            known_tasks.each do |parent|
                parent.each_relation do |rel|
                    m_parent = mappings[parent]
                    parent.each_child_object(rel) do |child|
                        info = parent[child, rel]
                        rel.add_relation(m_parent, mappings[child], info)
                    end
                end

                parent.each_event do |parent_ev|
                    m_parent_ev = mappings[parent_ev]
                    parent_ev.each_relation do |rel|
                        parent_ev.each_child_object(rel) do |child_ev, info|
                            m_child_ev = mappings[child_ev]
                            if !rel.linked?(m_parent_ev, m_child_ev)
                                rel.add_relation(m_parent_ev, m_child_ev, info)
                            end
                        end
                    end
                end
            end

            free_events.each do |parent_ev|
                m_parent_ev = mappings[parent_ev]
                parent_ev.each_relation do |rel|
                    parent_ev.each_child_object(rel) do |child_ev, info|
                        m_child_ev = mappings[child_ev]
                        rel.add_relation(m_parent_ev, m_child_ev, info)
                    end
                end
            end

            mappings
        end

	# call-seq:
	#   plan.partition_event_task(objects) => events, tasks
	#
	def partition_event_task(objects)
            if objects.respond_to?(:as_plan)
                objects = objects.as_plan
            end

	    if objects.respond_to?(:to_task) then return nil, [objects.to_task]
	    elsif objects.respond_to?(:to_event) then return [objects.to_event], nil
	    elsif !objects.respond_to?(:each)
		raise TypeError, "expecting a task, event, or a collection of tasks and events, got #{objects}"
	    end

	    evts, tasks = objects.partition do |o|
                if o.respond_to?(:as_plan)
                    o = o.as_plan
                end

		if o.respond_to?(:to_event) then true
		elsif o.respond_to?(:to_task) then false
		else raise ArgumentError, "found #{o || 'nil'} which is neither a task nor an event"
		end
	    end
	    return evts, tasks
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

        # Returns the set of stacked transaction, starting at +self+
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

	    @missions << task
	    add(task)
	    task.mission = true if task.self_owned?
	    added_mission(task)
	    self
	end
        def insert(task) # :nodoc:
            Roby.warn_deprecated "#insert has been replaced by #add_mission"
            add_mission(task)
        end
	# Hook called when +tasks+ have been inserted in this plan
	def added_mission(tasks)
            super if defined? super 
            if respond_to?(:inserted)
                Roby.warn_deprecated "the #inserted hook has been replaced by #added_mission"
                inserted(tasks)
            end
        end
	# Checks if +task+ is a mission of this plan
	def mission?(task); @missions.include?(task.to_task) end

        def remove_mission(task) # :nodoc:
            Roby.warn_deprecated "#remove_mission renamed #unmark_mission"
            unmark_mission(task)
        end

	# Removes the task in +tasks+ from the list of missions
	def unmark_mission(task)
            task = task.to_task
	    @missions.delete(task)
	    task.mission = false if task.self_owned?

	    unmarked_mission(task)
	    self
	end
	# Hook called when +tasks+ have been discarded from this plan
	def unmarked_mission(task)
            super if defined? super
            if respond_to?(:removed_mission)
                Roby.warn_deprecated "the #removed_mission hook has been replaced by #unmarked_mission"
                removed_mission(task)
            end
            if respond_to?(:discarded)
                Roby.warn_deprecated "the #discarded hook has been replaced by #unmarked_mission"
                discarded(task)
            end
        end
        def discard(task) # :nodoc:
            Roby.warn_deprecated "#discard has been replaced by #unmark_mission"
            unmark_mission(task)
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

            if object.kind_of?(Task)
                @permanent_tasks << object
            else
                @permanent_events << object
            end
	    add(object)
            self
	end

        def permanent(object) # :nodoc:
            Roby.warn_deprecated "#permanent has been replaced by #add_permanent"
            add_permanent(object)
        end

	# Removes +object+ from the list of permanent objects. Permanent objects
        # are protected from the plan's garbage collection. This does not remove
        # the task/event itself from the plan.
        #
        # See also #add_permanent and #permanent?
	def unmark_permanent(object)
            if object.respond_to?(:to_task)
                @permanent_tasks.delete(object.to_task) 
            elsif object.respond_to?(:to_event)
                @permanent_events.delete(object.to_event)
            else
                raise ArgumentError, "expected a task or event and got #{object}"
            end
        end

        def auto(obj) # :nodoc:
            Roby.warn_deprecated "#auto has been replaced by #unmark_permanent"
            unmark_permanent(obj)
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

	def edit
	    if block_given?
		Roby.synchronize do
		    yield
		end
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
            elsif to.plan && to.plan != self
                raise ArgumentError, "trying to replace #{to} but its plan is #{to.plan}, expected #{self}"
            elsif from == to
                return 
            end

	    # Swap the subplans of +from+ and +to+
	    yield(from, to)

	    if mission?(from)
		unmark_mission(from)
		add_mission(to)
	    elsif permanent?(from)
		unmark_permanent(from)
		add_permanent(to)
	    else
		add(to)
	    end
	    replaced(from, to)
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

            set = (plan_services[service.task] ||= ValueSet.new)
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

	# Hook called when +replacing_task+ has replaced +replaced_task+ in this plan
	def replaced(replaced_task, replacing_task)
            # Make the PlanService object follow the replacement
            if services = plan_services.delete(replaced_task)
                services.each do |srv|
                    srv.task = replacing_task
                    (plan_services[replacing_task] ||= ValueSet.new) << srv
                end
            end
            super if defined? super
        end

	# Check that this is an executable plan. This is always true for
	# plain Plan objects and false for transcations
	def executable?; true end

        def discover(objects) # :nodoc:
            Roby.warn_deprecated "#discover has been replaced by #add"
            add(objects)
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
	    events, tasks = partition_event_task(objects)

	    if tasks && !tasks.empty?
                tasks = tasks.to_value_set
		new_tasks = discover_new_objects(TaskStructure.relations, nil, known_tasks.dup, tasks)
		if !new_tasks.empty?
		    add_task_set(new_tasks)
                    events ||= ValueSet.new
                    for t in new_tasks
                        for ev in t.bound_events.values
                            task_events << ev
                            events << ev
                        end
                    end
		end
	    end

	    if events && !events.empty?
		events = events.to_value_set
                new_events = discover_new_objects(EventStructure.relations, nil, free_events.dup, events)

                # Issue added_task_relation hooks for the relations between the new
                # events, including task events
                #
                # If some of these events already have relations with existing tasks,
                # they will be triggered in Task#added_child_object
                new_events.each do |e|
                    e.each_root_relation do |rel|
                        e.each_child_object do |child_e|
                            if new_events.include?(child_e)
                                added_event_relation(e, child_e, rel.recursive_subsets)
                            end
                        end
                    end
                end
                new_events.delete_if { |ev| ev.respond_to?(:task) }
		add_event_set(new_events)
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

	# Add +events+ to the set of known events and call added_events
	# for the new events
	#
	# This is for internal use, use #add instead
	def add_event_set(events)
            for e in events
                e.plan = self
                free_events << e
	    end

	    if !events.empty?
		added_events(events)
	    end

	    events
	end

	# Add +tasks+ to the set of known tasks and call added_tasks for
	# the new tasks
	#
	# This is for internal use, use #add instead
	def add_task_set(tasks)
	    for t in tasks
		t.plan = self
                known_tasks << t
		task_index.add t
	    end
	    added_tasks(tasks)

	    for t in tasks
		t.instantiate_model_event_relations
	    end
	    nil
	end

        def added_tasks(tasks)
            if respond_to?(:discovered)
                Roby.warn_deprecated "the #discovered hook is deprecated, use #added_tasks instead"
                discovered(tasks)
            end
            if respond_to?(:discovered_tasks)
                Roby.warn_deprecated "the #discovered_tasks hook is deprecated, use #added_tasks instead"
                discovered_tasks(tasks)
            end

            if engine
                engine.event_ordering.clear
            end

            # Issue added_task_relation hooks for the relations between the new
            # tasks themselves
            #
            # If some of these tasks already have relations with existing tasks,
            # they will be triggered in Task#added_child_object
            tasks.each do |t|
                t.each_root_relation do |rel|
                    t.each_child_object do |child_t|
                        if tasks.include?(child_t)
                            added_task_relation(t, child_t, rel.recursive_subsets)
                        end
                    end
                end
                triggers.each do |trigger|
                    if trigger === t
                        trigger.call(t)
                    end
                end
            end

            super if defined? super
        end

	# Hook called when new events have been discovered in this plan
	def added_events(events)
            if respond_to?(:discovered_events)
                Roby.warn_deprecated "the #discovered_events hook has been replaced by #added_events"
                discovered_events(events)
            end

            if engine
                engine.event_ordering.clear
            end

	    super if defined? super
	end

        # Hook called when relations are created between tasks that are included
        # in this plan 
        #
        # @param [Task] parent
        # @param [Task] child
        # @param [Array<RelationGraph>] relations the relation graphs in which
        #   the new relation has been created
        # @return [void]
        def added_task_relation(parent, child, relations)
            super if defined? super
        end

        # Hook called when relations are removed between tasks that are included
        # in this plan 
        #
        # @param [Task] parent
        # @param [Task] child
        # @param [Array<RelationGraph>] relations the relation graphs in which
        #   the relation has been removed
        # @return [void]
        def removed_task_relation(parent, child, relations)
            super if defined? super
        end

        # Hook called when relations are created between events that are included
        # in this plan 
        #
        # @param [Task] parent
        # @param [Task] child
        # @param [Array<RelationGraph>] relations the relation graphs in which
        #   the new relation has been created
        # @return [void]
        def added_event_relation(parent, child, relations)
            if engine && relations.include?(Roby::EventStructure::Precedence)
                engine.event_ordering.clear
            end
            super if defined? super
        end

        # Hook called when relations are removed between tasks that are included
        # in this plan 
        #
        # @param [Task] parent
        # @param [Task] child
        # @param [Array<RelationGraph>] relations the relation graphs in which
        #   the relation has been removed
        # @return [void]
        def removed_event_relation(parent, child, relations)
            if engine && relations.include?(Roby::EventStructure::Precedence)
                engine.event_ordering.clear
            end
            super if defined? super
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

	# Merges the set of tasks that are useful for +seeds+ into +useful_set+.
	# Only the tasks that are in +complete_set+ are included.
	def discover_new_objects(relations, complete_set, useful_set, seeds, explored_relations = Hash.new)
            new_objects = ValueSet.new
            useful_set.merge(seeds)
	    for rel in relations
		next if !rel.root_relation?

                explored_relations[rel] ||= [ValueSet.new, ValueSet.new]

                reverse_seeds = seeds - explored_relations[rel][0]
		for subgraph in rel.reverse.generated_subgraphs(reverse_seeds, false)
                    explored_relations[rel][0].merge(subgraph)
		    new_objects.merge(subgraph)
		end

                direct_seeds = seeds - explored_relations[rel][1]
		for subgraph in rel.generated_subgraphs(direct_seeds, false)
                    explored_relations[rel][1].merge(subgraph)
		    new_objects.merge(subgraph)
		end
	    end

	    if complete_set
		new_objects.delete_if { |obj| !complete_set.include?(obj) }
	    end

            new_objects.difference!(seeds)
            new_objects.delete_if { |t| useful_set.include?(t) }
            if new_objects.empty?
                seeds
            else
                useful_set.merge(new_objects)
                seeds.merge(discover_new_objects(relations, complete_set, useful_set, new_objects, explored_relations))
            end
	end

	# Merges the set of tasks that are useful for +seeds+ into +useful_set+.
	# Only the tasks that are in +complete_set+ are included.
	def useful_task_component(complete_set, useful_set, seeds)
	    old_useful_set = useful_set.dup
	    for rel in TaskStructure.relations
		next if !rel.root_relation?
		for subgraph in rel.generated_subgraphs(seeds, false)
		    useful_set.merge(subgraph)
		end
	    end

	    if complete_set
		useful_set &= complete_set
	    end

	    if useful_set.size == old_useful_set.size || (complete_set && useful_set.size == complete_set.size)
		useful_set
	    else
		useful_task_component(complete_set, useful_set, (useful_set - old_useful_set))
	    end
	end

	# Returns the set of useful tasks in this plan
	def locally_useful_tasks
	    # Create the set of tasks which must be kept as-is
	    seeds = @missions | @permanent_tasks
	    for trsc in transactions
		seeds.merge trsc.proxy_objects.keys.to_value_set
	    end

	    return ValueSet.new if seeds.empty?

	    # Compute the set of LOCAL tasks which serve the seeds.  The set of
	    # locally_useful_tasks is the union of the seeds and of this one 
	    useful_task_component(local_tasks, seeds & local_tasks, seeds) | seeds
	end

	def local_tasks
	    task_index.by_owner[Roby::Distributed] || ValueSet.new
	end

	def remote_tasks
	    if local_tasks = task_index.by_owner[Roby::Distributed]
		known_tasks - local_tasks
	    else
		known_tasks
	    end
	end

	# Returns the set of unused tasks
	def unneeded_tasks
	    # Get the set of local tasks that are serving one of our own missions or
	    # permanent tasks
	    useful = self.locally_useful_tasks

	    # Append to that the set of tasks that are useful for our peers and
	    # include the set of local tasks that are serving tasks in
	    # +remotely_useful+
	    remotely_useful = Distributed.remotely_useful_objects(remote_tasks, true, nil)
	    serving_remote = useful_task_component(local_tasks, useful & local_tasks, remotely_useful)

	    useful.merge remotely_useful
	    useful.merge serving_remote

	    (known_tasks - useful)
	end

	# Computes the set of useful tasks and checks that +task+ is in it.
	# This is quite slow. It is here for debugging purposes. Do not use it
	# in production code
	def useful_task?(task)
	    known_tasks.include?(task) && !unneeded_tasks.include?(task)
	end

	def useful_event_component(useful_events)
	    current_size = useful_events.size
	    for rel in EventStructure.relations
		next unless rel.root_relation?

		for subgraph in rel.components(free_events, false)
		    subgraph = subgraph.to_value_set
		    if subgraph.intersects?(useful_events) || subgraph.intersects?(task_events)
			useful_events.merge(subgraph)
			if useful_events.include_all?(free_events)
			    return free_events
			end
		    end
		end

		if useful_events.include_all?(free_events)
		    return free_events
		end
	    end

	    if current_size != useful_events.size
		useful_event_component(useful_events)
	    else
		useful_events
	    end
	end

	# Computes the set of events that are useful in the plan Events are
	# 'useful' when they are chained to a task.
	def useful_events
	    return ValueSet.new if free_events.empty?
	    (free_events & useful_event_component(permanent_events.dup))
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
	def empty?; @known_tasks.empty? end
	# Iterates on all tasks
	def each_task; @known_tasks.each { |t| yield(t) } end
 
	# Returns +object+ if object is a plan object from this plan, or if
	# it has no plan yet (in which case it is added to the plan first).
	# Otherwise, raises ArgumentError.
	#
	# This method is provided for consistency with Transaction#[]
	def [](object, create = true)
            if !object.plan && !object.finalized?
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
	    @force_gc.delete(object)
            @task_index.remove(object)
            @gc_quarantine.delete(object)
            
            case object
            when Task
                for ev in object.bound_events
		    @task_events.delete(ev[1])
                end
            end

            finalize_object(object, timestamp)

	    self
	end

	# Remove all tasks
	def clear
	    known_tasks, @known_tasks = @known_tasks, ValueSet.new
	    free_events, @free_events = @free_events, ValueSet.new

	    @free_events.clear
	    @missions.clear
	    @known_tasks.clear
	    @permanent_tasks.clear
	    @permanent_events.clear
            @force_gc.clear
            @task_index.clear
            @task_events.clear
            @gc_quarantine.clear

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


	# Hook called when +task+ is marked as garbage. It will be garbage
	# collected as soon as possible
	def garbage(task_or_event)
	    # Remove all signals that go *to* the task
	    #
	    # While we want events which come from the task to be properly
	    # forwarded, the signals that go to the task are to be ignored
	    if task_or_event.respond_to?(:each_event) && task_or_event.self_owned?
		task_or_event.each_event do |ev|
		    for signalling_event in ev.parent_objects(EventStructure::Signal).to_a
			signalling_event.remove_signal ev
		    end
		end
	    end

	    super if defined? super

            remove_object(task_or_event)
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
            if engine && executable?
                engine.finalized_event(event)
            end
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

	# Replace +task+ with a fresh copy of itself and start it.
        #
        # See #recreate for details about the new task.
	def respawn(task)
            new = recreate(task)
            engine.once { new.start!(nil) }
	    new
	end
        
        # The set of blocks that should be called to check the structure of the
        # plan. See also Plan.structure_checks.
        attr_reader :structure_checks

        @structure_checks = Array.new
        class << self
            # A set of structure checking procedures that must be performed on all plans
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

        # Perform the structure checking step by calling the procs registered
        # in #structure_checks and Plan.structure_checks. These procs are
        # supposed to return a collection of exception objects, or nil if no
        # error has been found
	def check_structure
	    # Do structure checking and gather the raised exceptions
	    exceptions = {}
	    for prc in (Plan.structure_checks + structure_checks)
		begin
		    new_exceptions = prc.call(self)
		rescue Exception => e
                    if engine
                        engine.add_framework_error(e, 'structure checking')
                    else
                        raise
                    end
		end
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

        include Roby::ExceptionHandlingObject

        attr_reader :exception_handlers
        def each_exception_handler(&iterator); exception_handlers.each(&iterator) end
        def on_exception(matcher, &handler)
            check_arity(handler, 2)
            exception_handlers.unshift [matcher.to_execution_exception_matcher, handler]
        end

        # Finds a single difference between this plan and the other plan, using
        # the provided mappings to map objects from self to object in other_plan
        def find_plan_difference(other_plan, mappings)
            all_self_objects = known_tasks | free_events

            all_other_objects = (other_plan.known_tasks | other_plan.free_events)
            all_mapped_objects = all_self_objects.map do |obj|
                if !mappings.has_key?(obj)
                    return [:new_object, obj]
                end
                mappings[obj]
            end.to_value_set
            if all_mapped_objects != all_other_objects
                return [:removed_objects, all_other_objects - all_mapped_objects]
            end
            all_self_objects.each do |self_obj|
                other_obj = mappings[self_obj]

                self_obj.each_relation do |rel|
                    self_children  = self_obj.enum_child_objects(rel).to_a
                    other_children = other_obj.enum_child_objects(rel).to_a
                    return [:child_mismatch, self_obj, other_obj] if self_children.size != other_children.size

                    for self_child in self_children
                        self_info = self_obj[self_child, rel]
                        other_child = mappings[self_child]
                        return [:removed_child, self_obj, rel, self_child, other_child] if !other_obj.child_object?(other_child, rel)
                        other_info = other_obj[other_child, rel]
                        return [:info_mismatch, self_obj, rel, self_child, other_child] if !other_obj.child_object?(other_child, rel)
                    end
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
        #   plan.find_tasks(Tasks::SimpleTask, :id => 20)
        #
        # is equivalent to
        #
        #   Roby::Query.new(self).which_fullfills(Tasks::SimpleTask, :id => 20)
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
                result = ValueSet.new
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

	# Given the result set of +query+, returns the subset of tasks which
	# have no parent in +query+
	def query_roots(result_set, relation) # :nodoc:
	    children = ValueSet.new
	    found    = ValueSet.new
	    for task in result_set
		next if children.include?(task)
		task_children = task.generated_subgraph(relation)
		found -= task_children
		children.merge(task_children)
		found << task
	    end
	    found
	end
    end
end

