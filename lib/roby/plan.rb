require 'roby/event'
require 'roby/task'
require 'roby/relations'
require 'roby/basic_object'

module Roby
    class InvalidPlanOperation < RuntimeError; end
    class InvalidReplace < RuntimeError
	attr_reader :from, :to, :error
	def initialize(from, to, error)
	    @from, @to, @error = from, to, error
	end
	def message
	    "#{error} while replacing #{from} by #{to}"
	end
    end

    class PlanModelViolation < ModelViolation; end

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
	# The list of tasks that are included in this plan
	attr_reader :known_tasks
	# The list of missions in this plan
	attr_reader :missions
	# The list of events that are not included in a task
	attr_reader :free_events
	# The list of tasks that are kept outside GC
	attr_reader :keepalive

	# The hierarchy relation
	attr_reader :hierarchy
	# A list of "service" relations that should be considered during GC. If
	# a task is the parent of a useful task in a service relation, then
	# this task is tagged as useful
	attr_reader :service_relations

	attr_reader :all_relations

	# A set of tasks which are useful (and as such would not been garbage
	# collected), but we want to GC anyway
	attr_reader :force_gc

	# The set of transactions which are built on top of this plan
	attr_reader :transactions

	# If this object is the main plan, checks if we are subscribed to 
	# the whole remote plan
	def sibling_on?(peer)
	    if Roby.plan == self then peer.remote_plan
	    else super
	    end
	end

	def initialize(hierarchy = Roby::TaskStructure::Hierarchy, service_relations = [Roby::TaskStructure::PlannedBy, Roby::TaskStructure::ExecutionAgent])
	    @hierarchy = hierarchy
	    @service_relations = service_relations
	    @missions	 = ValueSet.new
	    @keepalive   = ValueSet.new
	    @known_tasks = ValueSet.new
	    @free_events = ValueSet.new
	    @force_gc    = ValueSet.new
	    @transactions = ValueSet.new
	    @all_relations = [@hierarchy] + @service_relations

	    super() if defined? super
	end

	def inspect
	    "#<#{to_s}: missions=#{missions.to_s} tasks=#{known_tasks.to_s} events=#{free_events.to_s} transactions=#{transactions.to_s}>"
	end

	# call-seq:
	#   plan.partition_event_task(objects) => events, tasks
	#
	def partition_event_task(objects)
	    if objects.respond_to?(:to_task) then return *[[], [objects.to_task]]
	    elsif objects.respond_to?(:to_event) then return *[[objects.to_event], []]
	    elsif !objects.respond_to?(:each)
		raise TypeError, "expecting a task, event, or a collection of tasks and events, got #{objects}"
	    end

	    objects.partition do |o| 
		if o.respond_to?(:to_event) then true
		elsif o.respond_to?(:to_task) then false
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

	# Inserts a new mission in the plan. Its child tree is automatically
	# inserted too.  Returns the plan
        def insert(task)
	    return if @missions.include?(task)

	    discover(task)
	    @missions << task
	    task.mission = true if task.self_owned?
	    inserted(task)
	    self
	end
	# Hook called when +tasks+ have been inserted in this plan
	def inserted(tasks); super if defined? super end
	alias :<< :insert

	# Forbid the GC to take out +task+
	def permanent(task)
	    discover(task)
	    @keepalive << task
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
	    discover(task)
	    @missions.delete(task)
	    task.mission = false if task.self_owned?

	    discarded(task)
	    self
	end
	# Hook called when +tasks+ have been discarded from this plan
	def discarded(tasks); super if defined? super end

	# Remove all tasks
	def clear
	    @known_tasks.each { |t| t.clear_relations }
	    @known_tasks.clear
	    @free_events.each { |e| e.clear_relations }
	    @free_events.clear
	    @missions.clear
	    @keepalive.clear
	end

	# Replaces +from+ by +to+. If +to+ cannot replace +from+, an
	# InvalidReplace exception is raised.
	def replace(from, to)
	    return if from == to

	    # Check that +to+ is valid in all hierarchy relations where +from+ is a child
	    if !to.fullfills?(*from.fullfilled_model)
		raise InvalidReplace.new(from, to, "to does not fullfills #{from.fullfilled_model}")
	    end

	    # Check that +to+ is in the same execution state than +from+
	    if !to.compatible_state?(from)
		raise InvalidReplace.new(from, to, "state")
	    end

	    # Copy all graph relations on +from+ events that are in +to+
	    from.replace_by(to)

	    replaced(from, to)
	    if mission?(from)
		discard(from)
		insert(to)
	    else
		discover(to)
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
	def discover(objects = nil)
	    events, tasks = partition_event_task(objects)

	    events = events.to_value_set
	    unless events.empty?
		discover_event_set(events)
	    end

	    tasks  = tasks.to_value_set
	    unless tasks.empty?
		new_tasks = useful_task_component(tasks, tasks.to_a)
		unless new_tasks.empty?
		    discover_task_set(new_tasks)
		end
	    end

	    self
	end

	# Add +events+ to the set of known events and call discovered_events
	# for the new events
	#
	# This is for internal use, use #discover instead
	def discover_event_set(events)
	    events.each do |e| 
		if !e.root_object?
		    raise ArgumentError, "trying to discover #{e} which is a non-root event"
		end
		e.plan = self
	    end

	    events = events.difference(free_events)
	    free_events.merge(events)
	    discovered_events(events)
	end

	# Add +tasks+ to the set of known tasks and call discovered_tasks for
	# the new tasks
	#
	# This is for internal use, use #discover instead
	def discover_task_set(tasks)
	    tasks = tasks.difference(known_tasks)
	    tasks.each { |t| t.plan = self }
	    known_tasks.merge tasks
	    discovered_tasks(tasks)
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

	# Returns the set of tasks that are useful for +tasks+
	def useful_task_component(useful_tasks, seeds)
	    old_useful_tasks = useful_tasks.dup
	    TaskStructure.each_relation do |rel| 
		next unless rel.root_relation?
		rel.generated_subgraphs(seeds, false).each do |subgraph|
		    useful_tasks.merge(subgraph)
		end
	    end

	    if useful_tasks.size == old_useful_tasks.size
		useful_tasks
	    else
		useful_task_component(useful_tasks, (useful_tasks - old_useful_tasks).to_a)
	    end
	end
	private :useful_task_component

	# Returns the set of useful tasks in this plan
	def locally_useful_tasks
	    # Remove all missions that are finished
	    @missions.find_all { |t| t.finished? }.
		each { |t| discard(t) }
	    @keepalive.find_all { |t| t.finished? }.
		each { |t| auto(t) }

	    all = @missions | @keepalive
	    return ValueSet.new if all.empty?
	    useful_task_component(all, all.to_a)
	end

	# Returns the set of unused tasks
	def unneeded_tasks
	    # Get the set of tasks that are serving one of our own missions or
	    # permanent tasks
	    useful = self.locally_useful_tasks
	    
	    # Get in the remaining set the tasks that are useful because they
	    # are used in a transaction and compute the set of tasks that are
	    # needed by them
	    transaction_useful = (known_tasks - useful).find_all do |t| 
		transactions.any? { |trsc| trsc.wrap(t, false) }
	    end
	    useful.merge transaction_useful.to_value_set
	    useful = useful_task_component(useful, transaction_useful)

	    # Finally, get in the remaining set the tasks that are useful
	    # because of our peers. We then remove from the set all local tasks
	    # that are serving these
	    remotely_useful = (known_tasks - useful).find_all { |t| Roby::Distributed.keep?(t) }
	    useful.merge remotely_useful.to_value_set

	    useful_task_component(useful.dup, remotely_useful).each do |t|
		useful << t if t.self_owned?
	    end

	    (known_tasks - useful)
	end

	def useful_event_component(events)
	    useful_events = events.dup
	    free_events.each do |ev|
		next if useful_events.include?(ev)
		EventStructure.each_relation do |relation|
		    next unless relation.root_relation?
		    next unless event_set = relation.components([ev], false).first
		    useful = event_set.any? do |obj| 
			obj.kind_of?(Roby::TaskEventGenerator) ||
			    useful_events.include?(obj)
		    end
		    if useful
			useful_events << ev
			break
		    end
		end
	    end

	    if useful_events.size != free_events.size && useful_events.size != events.size
		useful_event_component(useful_events)
	    else
		useful_events
	    end
	end

	# Computes the set of events that are useful in the plan Events are
	# 'useful' when they are chained to a task.
	def useful_events
	    return ValueSet.new if free_events.empty?
	    useful_event_component(ValueSet.new)
	end

	# The set of events that can be removed from the plan
	def unneeded_events
	    (free_events - useful_events).delete_if do |ev|
		Roby::Distributed.keep?(ev) || 
		    transactions.any? { |trsc| trsc.wrap(ev, false) }
	    end
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

	    loop do
		tasks = unneeded_tasks | force_gc
		if tasks.all? { |t| t.pending? || t.finished? }
		    tasks.each do |t|
			Roby.debug "GC: #{t} is not running, removed"
			garbage(t)
			remove_object(t)
		    end
		    break
		end

		# Mark all root tasks as garbage
		tasks.delete_if do |t| 
		    if t.root?(TaskStructure::Hierarchy)
			garbage(t)
			false
		    else
			Roby.debug "GC: ignoring #{t}, it is not root"
			true
		    end
		end

		did_something = false
		tasks.each do |t| 
		    if !t.self_owned?
			Roby.debug "GC: #{t} is not local, removing it"
			remove_object(t)
			did_something = true
		    elsif t.starting?
			# wait for task to be started before killing it
			Roby.debug "GC: #{t} is starting"
		    elsif t.pending? || t.finished?
			Roby.debug "GC: #{t} is not running, removed"
			remove_object(t)
			did_something = true
		    elsif !t.finishing?
			if t.event(:stop).controlable?
			    Roby.debug "GC: stopped #{t}"
			    Roby::Control.once { t.stop!(nil) }
			else
			    Roby.debug "GC: ignored #{t}, it cannot be stopped"
			end
		    elsif t.finishing?
			Roby.debug "GC: waiting for #{t} to finish"
		    else
			Roby.debug "GC: ignored #{t}"
		    end
		end

		break unless did_something
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
		    raise ArgumentError, "#{object} has been removed at\n  #{object.removed_at.join("\n  ")}"
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
		# NOTE: we MUST use instance variables directly here. Otherwise,
		# transaction commits would be broken
		object.each_event { |ev| finalized_event(ev) }
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

	    replace(task, new_task)
	    Control.once { new_task.start!(nil) }
	    new_task
	end
    end
end

