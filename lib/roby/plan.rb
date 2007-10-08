require 'roby/event'
require 'roby/task'
require 'roby/relations'
require 'roby/basic_object'

module Roby
    # A plan object is a collection of tasks and events. In plans, tasks can be
    # +missions+ (#missions, #mission?), which means that they are the final
    # goals of the system. A task is +useful+ if it helps into the realization
    # of a mission (it is linked to a mission by #hierarchy_relation or one
    # of the #service_relations), and is not useful otherwise. #garbage_collect
    # removes the tasks that are not useful.
    #
    # The following event hooks are defined:
    #   * #inserted
    #   * #discarded
    #   * #discovered_tasks
    #   * #discovered_events
    #   * #replaced
    #   * #added_transaction
    #   * #removed_transaction
    #   * #garbage
    #   * #finalized_task
    #   * #finalized_event
    #
    class Plan < BasicObject
	extend Logger::Hierarchy
	extend Logger::Forward

	# The task index for this plan
	attr_reader :task_index

	# The list of tasks that are included in this plan
	attr_reader :known_tasks
	# The set of events that are defined by #known_tasks
	attr_reader :task_events
	# The list of missions in this plan
	attr_reader :missions
	# The list of events that are not included in a task
	attr_reader :free_events
	# The list of tasks that are kept outside GC
	attr_reader :keepalive

	# A map of event => task repairs. Whenever an exception is found,
	# exception propagation checks that no repair is defined for that
	# particular event or for events that are forwarded by it.
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

	def initialize
	    @missions	 = ValueSet.new
	    @keepalive   = ValueSet.new
	    @known_tasks = ValueSet.new
	    @free_events = ValueSet.new
	    @task_events = ValueSet.new
	    @force_gc    = ValueSet.new
	    @gc_quarantine = ValueSet.new
	    @transactions = ValueSet.new
	    @repairs     = Hash.new

	    @task_index  = Roby::TaskIndex.new

	    super() if defined? super
	end

	def inspect
	    "#<#{to_s}: missions=#{missions.to_s} tasks=#{known_tasks.to_s} events=#{free_events.to_s} transactions=#{transactions.to_s}>"
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

	# Inserts a new mission in the plan. Its child tree is automatically
	# inserted too.  Returns the plan
        def insert(task)
	    return if @missions.include?(task)

	    @missions << task
	    discover(task)
	    task.mission = true if task.self_owned?
	    inserted(task)
	    self
	end
	# Hook called when +tasks+ have been inserted in this plan
	def inserted(tasks); super if defined? super end
	alias :<< :insert

	# Forbid the GC to take out +task+
	def permanent(task)
	    @keepalive << task
	    discover(task)
	end

	# Make GC finalize +task+ if it is not useful anymore
	def auto(task); @keepalive.delete(task) end

	def edit
	    if block_given?
		Roby::Control.synchronize do
		    yield
		end
	    end
	end

	def permanent?(task); @keepalive.include?(task) end

	# Removes the task in +tasks+ from the list of missions
	def discard(task)
	    @missions.delete(task)
	    discover(task)
	    task.mission = false if task.self_owned?

	    discarded(task)
	    self
	end
	# Hook called when +tasks+ have been discarded from this plan
	def discarded(tasks); super if defined? super end

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
	    @keepalive.clear
	end

	def handle_replace(from, to)
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
		discard(from)
		insert(to)
	    elsif permanent?(from)
		auto(from)
		permanent(to)
	    else
		discover(to)
	    end
	end

	def replace_task(from, to)
	    handle_replace(from, to) do
		from.replace_by(to)
	    end
	end

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

	# call-seq:
	#   plan.discover([t1, t2, ...]) => plan
	#
	# Updates Plan#known_tasks with either the child tree of the tasks in
	# +objects+
	def discover(objects)
	    events, tasks = partition_event_task(objects)
	    events = if events then events.to_value_set
		     else ValueSet.new
		     end
	    if tasks
		tasks = tasks.to_value_set
		new_tasks = useful_task_component(nil, tasks, tasks)
		unless new_tasks.empty?
		    old_task_events = task_events.dup
		    new_tasks = discover_task_set(new_tasks)

		    # now, we include the set of free events that are linked to
		    # +new_tasks+ in +events+
		    EventStructure.each_root_relation do |rel|
			components = rel.generated_subgraphs(task_events - old_task_events, false)
			components.concat rel.reverse.generated_subgraphs(task_events - old_task_events, false)
			for c in components
			    events.merge(c.to_value_set - task_events - free_events)
			end
		    end

		    events.delete_if { |ev| !ev.root_object? }
		end
	    end

	    raise unless (task_events & events).empty?
	    if events
		discover_event_set(events)
	    end

	    self
	end

	# Add +events+ to the set of known events and call discovered_events
	# for the new events
	#
	# This is for internal use, use #discover instead
	def discover_event_set(events)
	    events = events.difference(free_events)
	    for e in events
		if !e.root_object?
		    raise ArgumentError, "trying to discover #{e} which is a non-root event"
		end
		e.plan = self
	    end

	    free_events.merge(events)
	    discovered_events(events)
	    events
	end

	# Add +tasks+ to the set of known tasks and call discovered_tasks for
	# the new tasks
	#
	# This is for internal use, use #discover instead
	def discover_task_set(tasks)
	    tasks = tasks.difference(known_tasks)
	    for t in tasks
		t.plan = self
		task_events.merge t.bound_events.values.to_value_set
		task_index.add t
	    end
	    known_tasks.merge tasks
	    discovered_tasks(tasks)

	    for t in tasks
		t.instantiate_model_event_relations
	    end
	    tasks
	end

	# DEPRECATED. Use #discovered_tasks instead
	def discovered(tasks); super if defined? super end
	# Hook called when new tasks have been discovered in this plan
	def discovered_tasks(tasks)
	    discovered(tasks)
	    super if defined? super
	end
	# Hook called when new events have been discovered in this plan
	def discovered_events(events)
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
		    discard(finished_mission)
		end
	    end
	    for finished_permanent in (@keepalive & task_index.by_state[:finished?])
		if !task_index.repaired_tasks.include?(finished_permanent)
		    auto(finished_permanent)
		end
	    end

	    # Create the set of tasks which must be kept as-is
	    seeds = @missions | @keepalive
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
	    (free_events & useful_event_component(ValueSet.new))
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
	def include?(task); @known_tasks.include?(task) end
	# Checks if +task+ is a mission of this plan
	def mission?(task); @missions.include?(task) end
	# Count of tasks in this plan
	def size; @known_tasks.size end
	# Returns true if there is no task in this plan
	def empty?; @known_tasks.empty? end
	# Iterates on all tasks
	def each_task; @known_tasks.each { |t| yield(t) } end

	# Install a plan repair for +failure_point+ with +task+. If +task+ is pending, it is started.
	def add_repair(failure_point, task)
	    if !failure_point.kind_of?(Event)
		raise TypeError, "failure point #{failure_point} should be an event"
	    elsif task.plan && task.plan != self
		raise ArgumentError, "wrong plan: #{task} is in #{task.plan}, not #{self}"
	    elsif repairs.has_key?(failure_point)
		raise ArgumentError, "there is already a plan repair defined for #{failure_point}: #{repairs[failure_point]}"
	    elsif !task.plan
		discover(task)
	    end

	    repairs[failure_point] = task
	    if failure_point.generator.respond_to?(:task)
		task_index.repaired_tasks << failure_point.generator.task
	    end

	    if task.pending?
		Roby.once { task.start! }
	    end
	end

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
		discover(object)
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

	# Kills and removes all unneeded tasks
	def garbage_collect(force_on = nil)
	    if force_on && !force_on.empty?
		force_gc.merge(force_on.to_value_set)
	    end

	    # The set of tasks for which we queued stop! at this cycle
	    # #finishing? is false until the next event propagation cycle
	    finishing = ValueSet.new
	    did_something = true
	    while did_something
		did_something = false

		tasks = unneeded_tasks | force_gc
		local_tasks  = self.local_tasks & tasks
		remote_tasks = tasks - local_tasks

		# Remote tasks are simply removed, regardless of other concerns
		for t in remote_tasks
		    Plan.debug { "GC: removing the remote task #{t}" }
		    remove_object(t)
		end

		break if local_tasks.empty?

		if local_tasks.all? { |t| t.pending? || t.finished? }
		    local_tasks.each do |t|
			Plan.debug { "GC: #{t} is not running, removed" }
			garbage(t)
			remove_object(t)
		    end
		    break
		end

		# Mark all root local_tasks as garbage
		local_tasks.delete_if do |t|
		    if t.root?
			garbage(t)
			false
		    else
			Plan.debug { "GC: ignoring #{t}, it is not root" }
			true
		    end
		end

		(local_tasks - finishing - gc_quarantine).each do |local_task|
		    if local_task.pending? 
			Plan.info "GC: removing pending task #{local_task}"
			remove_object(local_task)
			did_something = true
		    elsif local_task.starting?
			# wait for task to be started before killing it
			Plan.debug { "GC: #{local_task} is starting" }
		    elsif local_task.finished?
			Plan.debug { "GC: #{local_task} is not running, removed" }
			remove_object(local_task)
			did_something = true
		    elsif !local_task.finishing?
			if local_task.event(:stop).controlable?
			    Plan.debug { "GC: queueing #{local_task}/stop" }
			    if !local_task.respond_to?(:stop!)
				Plan.fatal "something fishy: #{local_task}/stop is controlable but there is no #stop! method"
				gc_quarantine << local_task
			    else
				finishing << local_task
				Roby::Control.once do
				    Plan.debug { "GC: stopping #{local_task}" }
				    local_task.stop!(nil)
				end
			    end
			else
			    Plan.warn "GC: ignored #{local_task}, it cannot be stopped"
			    gc_quarantine << local_task
			end
		    elsif local_task.finishing?
			Plan.debug { "GC: waiting for #{local_task} to finish" }
		    else
			Plan.warn "GC: ignored #{local_task}"
		    end
		end
	    end

	    unneeded_events.each do |event|
		remove_object(event)
	    end
	end

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
	    @known_tasks.delete(object)
	    @keepalive.delete(object)
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

	# Backward compatibility
	def remove_task(t) # :nodoc:
	    remove_object(t)
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
	    super if defined? super
	    finalized(task)
	end
	# Hook called when +event+ has been removed from this plan
	def finalized_event(event); super if defined? super end

	# Replace +task+ with a fresh copy of itself
	def respawn(task)
	    new_task = task.class.new(task.arguments.dup)

	    replace_task(task, new_task)
	    Control.once { new_task.start!(nil) }
	    new_task
	end
    end
end

