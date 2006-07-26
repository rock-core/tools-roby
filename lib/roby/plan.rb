require 'set'
require 'roby/relations/hierarchy'
require 'facet/kernel/constant'
require 'facet/kernel/returning'

module Roby
    class Plan
	def size; @tasks.size end
	def initialize
	    @tasks = Set.new
	end

	# Merge +plan+ into this one
	def merge(plan)
	    plan.each_task { |task| @tasks << task }
	end

	def each_task(&iterator)
	    tasks.each(&iterator)
	end

	# List all tasks in the plan
	def tasks
	    tasks	= Set.new
	    new_tasks	= @tasks.dup
	    events	= Set.new
	    new_events	= Set.new
	    class << new_events # Make the 'events' set look like a relation node
		alias :each_related_object :each 
	    end

	    while task = new_tasks.find { true }
		next if tasks.include?(task)

		new_events.clear
		new_tasks.delete(task)
		tasks << task
		
		task.enum_bfs(:each_related_object) do |t|
		    if t.kind_of?(Task)
			tasks << t
			new_tasks.delete(t)
			new_events.merge t.enum_for(:each_event).
			    find_all { |ev| !events.include?(ev) }
		    end
		end

		new_tasks.merge	new_events.enum_bfs(:each_related_object).
		    find_all { |ev| !events.include?(ev) && ev.respond_to?(:task) && !tasks.include?(ev.task) }.
		    each { |ev| events << ev }.
		    map  { |ev| ev.task }.
		    to_set
	    end

	    tasks
	end

        def insert(task)
	    @tasks << task
	    @first_task = task
	    self
	end
	alias :<< :insert

	attr_reader :first_task
	def start!(context)
	    first_task.start!(context)
	end

	def query
	    Query.new(self)
	end

	def tasks_state
	    enum_for(:each_task).map do |task|
		state = if task.running?; "running"
			elsif task.finished?; "finished"
			else "pending"
			end

		last_event = task.history.last[1] unless task.history.empty?
		[task.class.name, task.object_id, state, last_event.inspect]
	    end
	end
    end

    # The query class represents a search in a plan. 
    # It can be used locally on any Plan object, but 
    # is mainly used as an argument to DRb::Server#find
    class Query
	attr_reader :model, :arguments
	def initialize(plan = nil)
	    @plan = plan
	end

	# shortcut to set both model and argument 
	def fullfills(model, arguments = nil)
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

	def self.add_to_result(result, found)
	    found = found.to_set
	    if result
		result &= found
	    else
		found
	    end
	end
	private_class_method :add_to_result

	def each(plan = nil)
	    plan ||= @plan
	    plan.enum_for(:each_task).each do |task|
		yield(task) if task.fullfills?(constant(model), arguments)
	    end
	    self
	end
	include Enumerable

	# Define singleton classes. For instance, calling Query.fullfills is equivalent
	# to Query.new.fullfills
	QUERY_METHODS = %w{fullfills with_model with_arguments}
	QUERY_METHODS.each do |name|
	    Query.singleton_class.class_eval do
		define_method(name) do |*args|
		    Query.new.send(name, *args)
		end
	    end
	end
    end
end

