require 'roby/graph'
require 'roby/relations/hierarchy'
require 'facet/kernel/constant'
require 'pp'

module Roby
    class Plan
	attr_reader :known_tasks, :missions

	def size; known_tasks.size end
	def initialize
	    @missions	 = ValueSet.new
	    @known_tasks = ValueSet.new
	end

        def insert(task)
	    discover(task)
	    missions << task
	    self
	end
	alias :<< :insert

	def discard(task)
	    discover(task)
	    missions.delete(task)
	    self
	end

	def discover(*tasks)
	    tasks = missions if tasks.empty?
	    @known_tasks = TaskStructure::Hierarchy.components(*tasks).
		inject(known_tasks) { |r, c| r.merge(c) }

	    self
	end

	def useful_tasks
	    TaskStructure::Hierarchy.components(*missions).
		inject do |useful, component|
		    useful.merge(component)
		end
	end

	def include?(task); known_tasks.include?(task) end
	def mission?(task); missions.include?(task) end
	def each_task
	    known_tasks.each { |t| yield(t) }
	end

	def find_tasks; Query.new(self) end
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
		    next unless task.fullfills?(constant(model), arguments) 
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

