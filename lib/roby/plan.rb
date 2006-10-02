require 'roby/graph'
require 'roby/relations/hierarchy'
require 'roby/relations/planned_by'
require 'facet/kernel/constant'
require 'pp'

module Roby
    class InvalidPlanOperation < RuntimeError
    end

    class InvalidReplace < RuntimeError
	def initialize(from, to, error)
	    @from, @to, @error = from, to, error
	end
    end

    class Plan
	attr_reader :known_tasks, :missions
	attr_reader :hierarchy, :service_relations

	def initialize(hierarchy = Roby::TaskStructure::Hierarchy, service_relations = [Roby::TaskStructure::PlannedBy])
	    @hierarchy = hierarchy
	    @service_relations = service_relations
	    @missions	 = ValueSet.new
	    @known_tasks = ValueSet.new
	end

	def apply(task)
	    if task.respond_to?(:each) then task.each { |t| yield(t.to_task) }
	    elsif task.respond_to?(:each_task) then task.each_task { |t| yield(t.to_task) }
	    elsif task.respond_to?(:to_task) then yield(task.to_task)
	    else raise TypeError, "expecting a task or a task collection, got #{task}"
	    end
	end

	# Inserts a new mission in the plan. Its child tree is automatically inserted too.
	# Returns the plan
        def insert(tasks)
	    apply(tasks) do |t|
		discover(t)
		@missions << t
		self
	    end
	    self
	end
	alias :<< :insert

	# Mark +task+ as not being a task anymore
	def discard(tasks)
	    apply(tasks) do |t|
		discover(t)
		@missions.delete(t)
	    end
	    self
	end

	# Remove all tasks
	def clear
	    known_tasks.each { |t| t.clear_relations }
	    known_tasks.clear
	    @missions.clear
	end

	# Replaces +from+ by +to+. If +to+ cannot replace +from+, an
	# InvalidReplace exception is raised.
	def replace(from, to)
	    # Check that +to+ is valid in all hierarchy relations where +from+ is a child
	    if !to.fullfills?(*from.fullfilled_model)
		raise InvalidReplace.new(from, to, "to does not fullfills the needed models")
	    end

	    # Check that +to+ is in the same execution state than +from+
	    if !to.same_state?(from)
		raise InvalidReplace.new(from, to, "state")
	    end

	    # Copy all graph relations on +from+ events that are in +to+
	    from.each_event do |ev|
		next unless to.has_event?(ev.symbol)
		ev.replace_vertex_by(to.event(ev.symbol))
	    end
	    from.replace_vertex_by(to)

	    if mission?(from)
		@missions.delete(from)
		@missions.insert(to)
	    else
		discover(to)
	    end
	end

	# call-seq:
	#   plan.discover(t1, t2, ...)	    => plan
	#   plan.discover		    => plan
	#
	# Updates Plan#known_tasks with either the child tree of t1, t2, ... or the missions
	# child trees.
	def discover(tasks = nil)
	    tasks = missions unless tasks
	    tasks = if tasks.respond_to?(:each_task) then tasks.enum_for(:each_task).to_a
		    elsif tasks.respond_to?(:each) then tasks.to_a
		    else [tasks]
		    end

	    @known_tasks.merge useful_component(tasks)

	    self
	end

	def useful_component(tasks)
	    # Get all tasks related by hierarchy
	    tasks = @hierarchy.directed_components(*tasks).
		inject { |tasks, component| tasks.merge(component) }

	    # Get all tasks related to a useful task by a service
	    # relation
	    tasks.dup.each do |t|
		@service_relations.each do |rel|
		    if rel.include?(t)
			tasks.merge t.directed_component(rel)
		    end
		end
	    end

	    tasks
	end

	# Returns the set of needed tasks
	def useful_tasks
	    return ValueSet.new if missions.empty?

	    # Remove all missions that are finished
	    missions.each { |t| discard(t) if t.finished? }

	    useful_component(missions)
	end

	# Returns the set of unused tasks
	def unneeded_tasks; known_tasks - useful_tasks end
	# Checks if +task+ is included in this plan
	def include?(task); known_tasks.include?(task) end
	# Checks if +task+ is a mission of this plan
	def mission?(task); missions.include?(task) end
	# Count of tasks in this plan
	def size; known_tasks.size end
	# Iterates on all tasks
	def each_task; known_tasks.each { |t| yield(t) } end
	# Returns a Query object on this plan
	def find_tasks; Query.new(self) end

	# Kills and removes all unneeded tasks
	def garbage_collect
	    children = unneeded_tasks
	    loop do
		roots, children = children.partition { |t| t.root?(TaskStructure::Hierarchy) }
		break if roots.empty?

		while t = roots.shift
		    if !t.running?
			remove_task(t)
		    elsif t.event(:stop).controlable? && !t.event(:stop).pending?
			t.stop!(nil)
			# 'stop' may have been achieved instantly
			# In that case, add it back to root so that it is handled here
			roots << t if t.finished?
		    end
		end
	    end
	end

	def remove_task(t)
	    t.clear_relations
	    @missions.delete(t)
	    @known_tasks.delete(t)
	    finalized(t)
	end

	def finalized(task); super if defined? super end
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

