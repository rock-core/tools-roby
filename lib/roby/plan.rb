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

	# A map of event => task repairs. Whenever an exception is found,
	# exception propagation checks that no repair is defined for that
	# particular event or for events that are forwarded by it.
        #
        # See also #add_repair and #remove_repair
	attr_reader :repairs

	# A set of tasks which are useful (and as such would not been garbage
	# collected), but we want to GC anyway
	attr_reader :force_gc

	# A set of task for which GC should not be attempted, either because
	# they are not interruptible or because their start or stop command
	# failed
	attr_reader :gc_quarantine

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
	    @repairs     = Hash.new
            @exception_handlers = Array.new

            @relations = TaskStructure.relations + EventStructure.relations
            @structure_checks = relations.
                map { |r| r.method(:check_structure) if r.respond_to?(:check_structure) }.
                compact

	    @task_index  = Roby::TaskIndex.new

	    super() if defined? super
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

	# call-seq:
	#   plan.partition_event_task(objects) => events, tasks
	#
	def partition_event_task(objects)
	    if objects.respond_to?(:to_task) then return nil, [objects.to_task]
	    elsif objects.respond_to?(:to_event) then return [objects.to_event], nil
	    elsif !objects.respond_to?(:each)
		raise TypeError, "expecting a task, event, or a collection of tasks and events, got #{objects}"
	    end

	    evts, tasks = objects.partition do |o|
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
	def mission?(task); @missions.include?(task) end

        def remove_mission(task) # :nodoc:
            Roby.warn_deprecated "#remove_mission renamed #unmark_mission"
            unmark_mission(task)
        end

	# Removes the task in +tasks+ from the list of missions
	def unmark_mission(task)
	    @missions.delete(task)
	    add(task)
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
            @permanent_tasks.delete(object) 
            @permanent_events.delete(object)
        end

        def auto(obj) # :nodoc:
            Roby.warn_deprecated "#auto has been replaced by #unmark_permanent"
            unmark_permanent(obj)
        end

        # True if +obj+ is neither a permanent task nor a permanent object.
        #
        # See also #add_permanent and #unmark_permanent
	def permanent?(obj); @permanent_tasks.include?(obj) || @permanent_events.include?(obj) end

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

	# Remove all tasks
	def clear
	    @known_tasks.each { |t| t.clear_relations }
	    @known_tasks.clear
	    @free_events.each { |e| e.clear_relations }
	    @free_events.clear
	    @missions.clear
	    @permanent_tasks.clear
	    @permanent_events.clear
	end

	def handle_replace(from, to) # :nodoc:
	    return if from == to

	    # Check that +to+ is valid in all hierarchy relations where +from+ is a child
	    if !to.fullfills?(*from.fullfilled_model)
		raise InvalidReplace.new(from, to, "to does not fullfills #{from.fullfilled_model}")
	    end

	    # Check that +to+ is in the same execution state than +from+
	    if !to.compatible_state?(from)
		raise InvalidReplace.new(from, to, "state. #{from.running?}, #{to.running?}")
	    end

	    # Swap the subplans of +from+ and +to+
	    yield(from, to)

	    replaced(from, to)
	    if mission?(from)
		unmark_mission(from)
		add_mission(to)
	    elsif permanent?(from)
		unmark_permanent(from)
		add_permanent(to)
	    else
		add(to)
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

	# Hook called when +to+ has replaced +from+ in this plan
	def replaced(from, to); super if defined? super end

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
	    event_seeds, tasks = partition_event_task(objects)
	    event_seeds = (event_seeds || ValueSet.new).to_value_set

	    if tasks
		tasks = tasks.to_value_set
		new_tasks = useful_task_component(nil, tasks, tasks)
		unless new_tasks.empty?
		    old_task_events = task_events.dup
		    new_tasks = add_task_set(new_tasks)
		    event_seeds.merge(task_events - old_task_events)
		end
	    end

	    if !event_seeds.empty?
		events = event_seeds.dup

		# now, we include the set of free events that are linked to
		# +new_tasks+ in +events+
		EventStructure.each_root_relation do |rel|
		    components = rel.generated_subgraphs(event_seeds, false)
		    components.concat rel.reverse.generated_subgraphs(event_seeds, false)
		    for c in components
			events.merge(c.to_value_set)
		    end
		end

		add_event_set(events - task_events - free_events)
	    end

	    self
	end

	# Add +events+ to the set of known events and call added_events
	# for the new events
	#
	# This is for internal use, use #add instead
	def add_event_set(events)
	    events = events.difference(free_events)
	    events.delete_if do |e|
		if !e.root_object?
		    true
		else
		    e.plan = self
		    false
		end
	    end

	    unless events.empty?
		free_events.merge(events)
		added_events(events)
	    end

	    events
	end

	# Add +tasks+ to the set of known tasks and call added_tasks for
	# the new tasks
	#
	# This is for internal use, use #add instead
	def add_task_set(tasks)
	    tasks = tasks.difference(known_tasks)
	    for t in tasks
		t.plan = self
		task_events.merge t.bound_events.values.to_value_set
		task_index.add t
	    end
	    known_tasks.merge tasks
	    added_tasks(tasks)

	    for t in tasks
		t.instantiate_model_event_relations
	    end
	    tasks
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
            super if defined? super
        end

	# Hook called when new events have been discovered in this plan
	def added_events(events)
            if engine
                engine.event_ordering.clear
            end

            if respond_to?(:discovered_events)
                Roby.warn_deprecated "the #discovered_events hook has been replaced by #added_events"
                discovered_events(events)
            end
	    super if defined? super
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
	def useful_task_component(complete_set, useful_set, seeds)
	    old_useful_set = useful_set.dup
	    for rel in TaskStructure.relations
		next unless rel.root_relation?
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
	    # Remove all missions that are finished
	    for finished_mission in (@missions & task_index.by_state[:finished?])
		if !task_index.repaired_tasks.include?(finished_mission)
		    unmark_mission(finished_mission)
		end
	    end
	    for finished_permanent in (@permanent_tasks & task_index.by_state[:finished?])
		if !task_index.repaired_tasks.include?(finished_permanent)
		    unmark_permanent(finished_permanent)
		end
	    end

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
 
        # Install a plan repair for +failure_point+ with +task+. A plan repair
        # is a task which, during its lifetime, is supposed to fix the problem
        # encountered at +failure_point+
        #
        # +failure_point+ is an Event object which represents the event causing
        # the problem.
        #
        # See also #repairs and #remove_repair
	def add_repair(failure_point, task)
	    if !failure_point.kind_of?(Event)
		raise TypeError, "failure point #{failure_point} should be an event"
	    elsif task.plan && task.plan != self
		raise ArgumentError, "wrong plan: #{task} is in #{task.plan}, not #{plan}"
	    elsif repairs.has_key?(failure_point)
		raise ArgumentError, "there is already a plan repair defined for #{failure_point}: #{repairs[failure_point]}"
	    elsif !task.plan
		add(task)
	    end

	    repairs[failure_point] = task
	    if failure_point.generator.respond_to?(:task)
		task_index.repaired_tasks << failure_point.generator.task
	    end
	end

        # Removes +task+ from the set of active plan repairs.
        #
        # See also #repairs and #add_repair
	def remove_repair(task)
	    repairs.delete_if do |ev, repair|
		if repair == task
		    if ev.generator.respond_to?(:task)
			task_index.repaired_tasks.delete(ev.generator.task)
		    end
		    true
		end
	    end
	end

	# Return all repairs which apply on +event+
	def repairs_for(event)
	    result = Hash.new

	    if event.generator.respond_to?(:task)
		equivalent_generators = event.generator.generated_subgraph(EventStructure::Forwarding)

		history = event.generator.task.history
		id    = event.propagation_id
		index = history.index(event)
		while index < history.size
		    ev = history[index]
		    break if ev.propagation_id != id

		    if equivalent_generators.include?(ev.generator) &&
			(task = repairs[ev])

			result[ev] = task
		    end

		    index += 1
		end
	    elsif task = repairs[event]
		result[event] = task
	    end

	    result
	end

	# Returns +object+ if object is a plan object from this plan, or if
	# it has no plan yet (in which case it is added to the plan first).
	# Otherwise, raises ArgumentError.
	#
	# This method is provided for consistency with Transaction#[]
	def [](object)
	    if object.plan != self
		raise ArgumentError, "#{object} is not from #{plan}"
	    elsif !object.plan
		add(object)
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

        # Remove +object+ from this plan. You usually don't have to do that
        # manually. Object removal is handled by the plan's garbage collection
        # mechanism.
	def remove_object(object)
	    if !object.root_object?
		raise ArgumentError, "cannot remove #{object} which is a non-root object"
	    elsif object.plan != self
		if known_tasks.include?(object) || free_events.include?(object)
		    raise ArgumentError, "#{object} is included in #{self} but #plan == #{object.plan}"
		elsif !object.plan
		    if object.removed_at
			raise ArgumentError, "#{object} has been removed at\n  #{object.removed_at.join("\n  ")}"
		    else
			raise ArgumentError, "#{object} has not been included in this plan"
		    end
		end
		raise ArgumentError, "#{object} is not in #{self}: #plan == #{object.plan}"
	    end

	    # Remove relations first. This is needed by transaction since
	    # removing relations may need wrapping some new objects, and in
	    # that case these new objects will be discovered as well
	    object.clear_relations

	    @free_events.delete(object)
	    @missions.delete(object)
            if object.respond_to? :mission=
                object.mission = false
            end
	    @known_tasks.delete(object)
	    @permanent_tasks.delete(object)
	    @permanent_events.delete(object)
	    force_gc.delete(object)

	    object.plan = nil
	    object.removed_at = caller

	    case object
	    when EventGenerator
		finalized_event(object)

	    when Task
		task_index.remove(object)

		for ev in object.bound_events.values
		    task_events.delete(ev)
		    finalized_event(ev)
		end
		finalized_task(object)

	    else
		raise ArgumentError, "unknown object type #{object}"
	    end

	    self
	end

	# Hook called when +task+ is marked as garbage. It will be garbage
	# collected as soon as possible
	def garbage(task)
	    # Remove all signals that go *to* the task
	    #
	    # While we want events which come from the task to be properly
	    # forwarded, the signals that go to the task are to be ignored
	    if task.self_owned?
		task.each_event do |ev|
		    ev.parent_objects(EventStructure::Signal).each do |signalling_event|
			signalling_event.remove_signal ev
		    end
		end
	    end

	    super if defined? super
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

	# Replace +task+ with a fresh copy of itself
	def respawn(task)
	    new_task = task.class.new(task.arguments.dup)

	    replace_task(task, new_task)
	    engine.once { new_task.start!(nil) }
	    new_task
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
            result = []
            for task in plan.missions
                result << MissionFailedError.new(task) if task.failed?
            end
            result
        end
        structure_checks << method(:check_failed_missions)
        
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

		[*new_exceptions].each do |e, tasks|
		    e = ExecutionEngine.to_execution_exception(e)
		    exceptions[e] = tasks
		end
	    end
	    exceptions
	end


        include Roby::ExceptionHandlingObject

        attr_reader :exception_handlers
        def each_exception_handler(&iterator); exception_handlers.each(&iterator) end
        def on_exception(*matchers, &handler)
            check_arity(handler, 2)
            exception_handlers.unshift [matchers, handler]
        end
    end

    class << self
        # Returns the main plan
        attr_reader :plan
    end
    
    # Defines a global exception handler on the main plan.
    # See also Plan#on_exception
    def self.on_exception(*matchers, &handler); Roby.plan.on_exception(*matchers, &handler) end
end
