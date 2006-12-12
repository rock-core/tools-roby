require 'facet/kernel/constant'
require 'roby/relations/hierarchy'
require 'roby/relations/planned_by'

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
	# The list of tasks that are included in this plan
	attr_reader :known_tasks
	# The list of missions in this plan
	attr_reader :missions
	# The list of events that are not included in a task
	attr_reader :free_events

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

	def initialize(hierarchy = Roby::TaskStructure::Hierarchy, service_relations = [Roby::TaskStructure::PlannedBy])
	    @hierarchy = hierarchy
	    @service_relations = service_relations
	    @missions	 = ValueSet.new
	    @known_tasks = ValueSet.new
	    @free_events = ValueSet.new
	    @force_gc    = ValueSet.new
	    @transactions = ValueSet.new
	end

	# call-seq:
	#   plan.partition_event_task(objects) => events, tasks
	#
	def partition_event_task(objects)
	    if objects.respond_to?(:each_task) then return *[[], objects.enum_for(:each_task).to_a]
	    elsif objects.respond_to?(:to_task) then return *[[], [objects.to_task]]
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
	    elsif objects.respond_to?(:each_task) then objects.each_task { |t| yield(t.to_task) }
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
        def insert(tasks)
	    task_collection(tasks) do |t|
		discover(t)
		@missions << t
		self
	    end
	    inserted(tasks)
	    self
	end
	# Hook called when +tasks+ have been inserted in this plan
	def inserted(tasks); super if defined? super end
	alias :<< :insert

	# Removes the task in +tasks+ from the list of missions
	def discard(tasks)
	    task_collection(tasks) do |t|
		discover(t)
		@missions.delete(t)
	    end
	    discarded(tasks)
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
		    discovered_tasks(new_tasks)
		    new_tasks.each { |t| t.plan = self }
		    @known_tasks.merge new_tasks
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
	    useful_tasks = ([@hierarchy] + @service_relations).
		map { |rel| rel.generated_subgraphs(*tasks) }.
		flatten.
		inject { |useful_tasks, component| useful_tasks.merge(component) }

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
	    return ValueSet.new if @missions.empty?

	    # Remove all missions that are finished
	    @missions.find_all { |t| t.finished? }.
		each { |t| discard(t) }
	    useful_component(@missions)
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
	# Returns a Query object on this plan
	def find_tasks; Query.new(self) end

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

	# Kills and removes all unneeded tasks
	def garbage_collect(force_on = [])
	    force_gc.merge(force_on)

	    loop do
		tasks = unneeded_tasks | force_gc
		did_something = false
		tasks.find_all { |t| t.root?(@hierarchy) }.
		    each do |t|
			if t.event(:start).pending?
			    # wait for task to be started before killing it
			elsif !t.running?
			    garbage(t)
			    remove_task(t)
			    did_something = true
			elsif t.event(:stop).controlable? && !t.event(:stop).pending?
			    garbage(t)
			    t.stop!(nil)
			    remove_task(t) unless t.running?
			    did_something = true
			end
		    end

		break unless did_something
	    end
	end

	def remove_object(object)
	    object.clear_relations

	    case object
	    when TaskEventGenerator
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
		finalized_task(object)
	    end

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
    end

    # The query class represents a search in a plan. 
    # It can be used locally on any Plan object, but 
    # is mainly used as an argument to DRb::Server#find
    class Query
	attr_reader :model, :arguments
	def initialize(plan = nil)
	    @plan    = plan
	    @improved_information   = []
	    @needed_information	    = []
	end

	# shortcut to set both model and argument 
	def which_fullfills(model, arguments = nil)
	    with_model(model).with_arguments(arguments)
	end

	# find by model
	def with_model(model)
	    # We keep only the module names since we want Query to 
	    # be marshallable
	    @model = if Class === model
			 model.name
		     else
			 model.to_str
		     end

	    self
	end
	
	# find by argument
	def with_arguments(arguments)
	    @arguments = arguments
	    self
	end

	# find tasks which improves information contained in +info+
	def which_improves(info)
	    @improved_information ||= Array.new
	    @improved_information << info
	    self
	end

	# find tasks which need information contained in +info+
	def which_needs(info)
	    @needed_information ||= Array.new
	    @needed_information << info
	    self
	end

	def each(plan = nil)
	    (plan || @plan).each_task do |task|
		if model
		    next unless task.fullfills?(constant(model), arguments || {}) 
		end
		next unless @improved_information.all? { |info| task.improves?(info) }
		next unless @needed_information.all? { |info| task.needs?(info) }
		yield(task)
	    end

	    self
	end
	include Enumerable

	def self.declare_class_method(name)
	    raise "no instance method #{name} on Query" unless Query.method_defined?(name)
	    Query.singleton_class.send(:define_method, name) do |*args|
		Query.new.send(name, *args)
	    end
	end
	# Define singleton classes. For instance, calling Query.which_fullfills is equivalent
	# to Query.new.which_fullfills
	%w{which_fullfills with_model with_arguments which_needs which_improves}.each do |name|
	    declare_class_method(name)
	end
    end
end

