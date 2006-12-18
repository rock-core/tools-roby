require 'roby/plan'
require 'roby/state/information'

module Roby
    class Plan
	# Returns a Query object on this plan
	def find_tasks; Query.new(self) end
    end

    # The query class represents a search in a plan. 
    # It can be used locally on any Plan object, but 
    # is mainly used as an argument to DRb::Server#find
    class TaskMatcher
	attr_reader :model, :arguments
	def initialize(plan = nil)
	    @improved_information   = []
	    @needed_information	    = []
	end

	# shortcut to set both model and argument 
	def which_fullfills(model, arguments = {})
	    with_model(model).with_arguments(arguments)
	end

	# find by model
	def with_model(model)
	    @model = model
	    self
	end
	
	# find by argument
	def with_arguments(arguments)
	    @arguments ||= Hash.new
	    @arguments = @arguments.merge(arguments) { |k, _, _| 
		raise ArgumentError, "a constraint has already been set on the #{k} argument" 
	    }
	    self
	end

	# find tasks which improves information contained in +info+
	attr_reader :improved_information
	def which_improves(*info)
	    @improved_information += info
	    self
	end

	# find tasks which need information contained in +info+
	attr_reader :needed_information
	def which_needs(*info)
	    @needed_information += info
	    self
	end

	def ===(task)
	    if model
		return unless task.model == model || task.kind_of?(model)
	    end
	    if arguments
		return unless task.arguments.slice(*arguments.keys) == arguments
	    end
	    return unless improved_information.all? { |info| task.improves?(info) }
	    return unless needed_information.all?   { |info| task.needs?(info) }
	    true
	end

	def each(plan)
	    plan.each_task do |task|
		yield(task) if self === task
	    end
	    self
	end

	def self.declare_class_method(name)
	    raise "no instance method #{name} on TaskMatcher" unless TaskMatcher.method_defined?(name)
	    TaskMatcher.singleton_class.send(:define_method, name) do |*args|
		TaskMatcher.new.send(name, *args)
	    end
	end
	# Define singleton classes. For instance, calling Query.which_fullfills is equivalent
	# to Query.new.which_fullfills
	%w{which_fullfills with_model with_arguments which_needs which_improves}.each do |name|
	    declare_class_method(name)
	end
    end

    class Query < TaskMatcher
	attr_reader :plan
	def initialize(plan)
	    @plan = plan
	    super()
	end
	def each; super(plan) end
	include Enumerable
    end
end

