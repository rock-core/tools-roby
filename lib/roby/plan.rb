require 'roby/event'
require 'roby/task'
require 'facet/kernel/constant'

module Roby
    class InvalidPlanOperation < RuntimeError; end
    class InvalidReplace < RuntimeError
	def initialize(from, to, error)
	    @from, @to, @error = from, to, error
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
    #   * #discovered
    #   * #replaced
    #   * #added_transaction
    #   * #removed_transaction
    #   * #garbage
    #   * #finalized_task
    #   * #finalized_event
    #
    class Plan
	include Distributed::LocalObject

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

	# A set of tasks which are useful (and as such would not been garbage
	# collected), but we want to GC anyway
	attr_reader :force_gc

	# The set of transactions which are built on top of this plan
	attr_reader :transactions

	def initialize(hierarchy = Roby::TaskStructure::Hierarchy, service_relations = [Roby::TaskStructure::PlannedBy, Roby::TaskStructure::ExecutionAgent])
	    @hierarchy = hierarchy
	    @service_relations = service_relations
	    @missions	 = ValueSet.new
	    @keepalive   = ValueSet.new
	    @known_tasks = ValueSet.new
	    @free_events = ValueSet.new
	    @force_gc    = ValueSet.new
	    @transactions = ValueSet.new
	end

	def inspect
	    "#<#{to_s}: missions=#{missions.to_s} tasks=#{known_tasks.to_s} events=#{free_events.to_s} transactions=#{transactions.to_s}>"
	end

	# call-seq:
	#   plan.partition_event_task(objects) => events, tasks
	#
	def partition_event_task(objects)
	    #if objects.respond_to?(:each_task) then return *[[], objects.enum_for(:each_task).to_a]
	    if objects.respond_to?(:to_task) then return *[[], [objects.to_task]]
	    elsif objects.respond_to?(:each_event) then return *[objects.enum_for(:each_event).to_a, []]
	    elsif objects.respond_to?(:to_event) then return *[[objects.to_event], []]
	    elsif !objects.respond_to?(:each)
		raise TypeError, "expecting a task, event, or a collection of tasks and events, got #{objects}"
	    end

	    return *objects.partition { |o| o.respond_to?(:to_event) }
	end

	# Checks that +objects+ is equivalent to an EventGenerator collection
	# and yields its elements
	def event_collection(objects)
	    if objects.respond_to?(:each) then objects.each { |e| yield(e.to_event) }
	    elsif objects.respond_to?(:each_event) then objects.each_event { |e| yield(e.to_event) }
	    elsif objects.respond_to?(:to_event) then yield(objects.to_event)
	    else
		raise TypeError, "expecting a event or a event collection, got #{objects}"
	    end
	end

	# Checks that +objects+ is equivalent to a Task collection and yields
	# its elements
	def task_collection(objects)
	    if objects.respond_to?(:each) then objects.each { |t| yield(t.to_task) }
	    #elsif objects.respond_to?(:each_task) then objects.each_task { |t| yield(t.to_task) }
	    elsif objects.respond_to?(:to_task) then yield(objects.to_task)
	    else
		raise TypeError, "expecting a task or a task collection, got #{objects}"
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

	def permanent?(task); @keepalive.include?(task) end

	# Removes the task in +tasks+ from the list of missions
	def discard(task)
	    discover(task)
	    @missions.delete(task)

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
		raise InvalidReplace.new(from, to, "to does not fullfills the needed models")
	    end

	    # Check that +to+ is in the same execution state than +from+
	    if !to.compatible_state?(from)
		raise InvalidReplace.new(from, to, "state")
	    end

	    # Copy all graph relations on +from+ events that are in +to+
	    from.each_event do |ev|
		next unless to.has_event?(ev.symbol)
		ev.replace_object_by(to.event(ev.symbol))
	    end
	    from.replace_object_by(to)

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
	#   plan.discover(t1, t2, ...)	    => plan
	#   plan.discover		    => plan
	#
	# Updates Plan#known_tasks with either the child tree of the tasks in
	# +objects+, or if +objects+ is nil the child tree of the plan missions
	def discover(objects = nil)
	    if !objects
		events, tasks = [], @missions
	    else
		events, tasks = partition_event_task(objects)
	    end

	    unless events.empty?
		events.each { |e| e.plan = self }
		@free_events.merge(events)
		discovered_events(events)
	    end
	    unless tasks.empty?
		new_tasks = useful_component(tasks).difference(@known_tasks)
		unless new_tasks.empty?
		    new_tasks.each { |t| t.plan = self }
		    @known_tasks.merge new_tasks
		    discovered_tasks(new_tasks)
		end
	    end

	    self
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
	# Hook called when a new transaction has been built on top of this plan
	def removed_transaction(trsc); super if defined? super end

	# Returns the component generated by +tasks+ which is useful in this plan
	def useful_component(tasks)
	    # Get all tasks related by hierarchy
	    useful_tasks = tasks.dup.to_value_set
	    ([@hierarchy] + @service_relations).each do |rel| 
		rel.generated_subgraphs(tasks.to_a, false).each do |subgraph|
		    useful_tasks.merge(subgraph)
		end
	    end

	    return ValueSet.new unless useful_tasks

	    if useful_tasks == tasks
		useful_tasks
	    else
		useful_component(useful_tasks)
	    end
	end
	private :useful_component

	# Returns the set of useful tasks
	def useful_tasks
	    # Remove all missions that are finished
	    @missions.find_all { |t| t.finished? }.
		each { |t| discard(t) }
	    @keepalive.find_all { |t| t.finished? }.
		each { |t| auto(t) }

	    all = @missions | @keepalive
	    return ValueSet.new if all.empty?
	    useful_component(all)
	end

	# Returns the set of unused tasks
	def unneeded_tasks; known_tasks - useful_tasks end
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

	# True if +task+ can be GCed once it is not useful
	def self.can_gc?(task)
	    if !task.self_owned? then false
	    elsif task.starting? then true # wait for the task to be started before deciding ...
	    elsif task.running? && !task.finishing?
		task.event(:stop).controlable?
	    else true
	    end
	end

	# Kills and removes all unneeded tasks
	def garbage_collect(force_on = [])
	    force_gc.merge(force_on)

	    loop do
		tasks = unneeded_tasks | force_gc
		did_something = false
		tasks.each do |t| 
		    next unless t.self_owned? && 
			t.root?(@hierarchy) && 
			service_relations.all? { |r| t.root?(r) }

		    if !t.local?
			raise NotImplementedError, "GC of non-local tasks is not implemented yet"
		    elsif t.starting?
			# wait for task to be started before killing it
			Roby.debug "cannot GC #{t} because it is starting"
		    elsif t.pending? || t.finished?
			garbage(t)
			Roby.debug "garbage-collecting #{t} because it is not running"
			remove_object(t)
			did_something = true
		    elsif !t.finishing?
			if t.event(:stop).controlable?
			    Roby.debug "stopping #{t} because it is being garbage-collected"
			    garbage(t)
			    t.stop!(nil)
			    remove_object(t) unless t.running?
			    did_something = true
			else
			    Roby.debug "cannot GC #{t} because its 'stop' event is not controlable"
			end
		    end
		end

		break unless did_something
	    end
	end

	def remove_object(object)
	    if !object.root_object?
		raise ArgumentError, "cannot remove a non-root object"
	    elsif object.plan != self
		if known_tasks.include?(object) || free_events.include?(object)
		    raise ArgumentError, "#{object} is included in #{self} but #plan == #{object.plan}"
		end
		raise ArgumentError, "#{object} is not in #{self}: #plan == #{object.plan}"
	    end

	    object.clear_relations

	    case object
	    when EventGenerator
		@free_events.delete(object)
		finalized_event(object)

	    when Task
		force_gc.delete(object)
		object.executable = false
		# NOTE: we MUST use instance variables directly here. Otherwise,
		# transaction commits would be broken
		@missions.delete(object)
		@known_tasks.delete(object)
		@keepalive.delete(object)
		object.each_event { |ev| finalized_event(ev) }
		finalized_task(object)

	    else 
		raise ArgumentError, "unknown object type #{object}"
	    end

	    object.freeze
	    self
	end

	# Backward compatibility
	def remove_task(t) # :nodoc:
	    remove_object(t) 
	end

	# Hook called when +task+ is marked as garbage. It will be garbage
	# collected as soon as possible
	def garbage(task); super if defined? super end

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

require 'roby/relations/events'
require 'roby/relations/hierarchy'
require 'roby/relations/planned_by'
require 'roby/relations/executed_by'

