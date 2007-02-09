require 'roby/plan'
require 'roby/state/information'

module Roby
    class Plan
	# Returns a Query object on this plan
	def find_tasks
	    Query.new(self)
	end
	def each_matching_task(matcher)
	    @known_tasks.each { |t| yield(t) if matcher === t }
	end
    end

    # The query class represents a search in a plan. 
    # It can be used locally on any Plan object, but 
    # is mainly used as an argument to DRb::Server#find
    class TaskMatcher
	attr_reader :model, :arguments
	attr_reader :predicates, :owners

	attr_reader :improved_information
	attr_reader :needed_information

	def initialize
	    @predicates           = ValueSet.new
	    @owners               = Set.new
	    @improved_information = ValueSet.new
	    @needed_information   = ValueSet.new
	end

	# Shortcut to set both model and argument 
	def which_fullfills(model, arguments = {})
	    with_model(model).with_model_arguments(arguments)
	end

	# Find by model
	def with_model(model)
	    @model = model
	    self
	end
	
	# Find by arguments defined by the model
	def with_model_arguments(arguments)
	    if !model
		raise ArgumentError, "set model first"
	    end
	    with_arguments(arguments.slice(*model.arguments))
	    self
	end

	# Find by argument (exact matching)
	def with_arguments(arguments)
	    @arguments ||= Hash.new
	    self.arguments.merge!(arguments) do |k, old, new| 
		if old != new
		    raise ArgumentError, "a constraint has already been set on the #{k} argument" 
		end
		old
	    end
	    self
	end

	# find tasks which improves information contained in +info+
	def which_improves(*info)
	    improved_information.merge(info)
	    self
	end

	# find tasks which need information contained in +info+
	def which_needs(*info)
	    needed_information.merge(info)
	    self
	end

	def owned_by(*ids)
	    owners.merge(ids.to_set)
	    self
	end
	def self_owned
	    owned_by(Roby::Distributed.remote_id)
	    self
	end

	class << self
	    def declare_class_methods(*names)
		names.each do |name|
		    raise "no instance method #{name} on TaskMatcher" unless TaskMatcher.method_defined?(name)
		    TaskMatcher.singleton_class.send(:define_method, name) do |*args|
			TaskMatcher.new.send(name, *args)
		    end
		end
	    end
	    def match_predicates(*names)
		names.each do |name|
		    class_eval <<-EOD
		    def #{name}
			predicates << :#{name}?
			self
		    end
		    EOD
		end
		declare_class_methods(*names)
	    end
	end
	match_predicates :local, :executable, :abstract, :partially_instanciated, :fully_instanciated,
	    :pending, :running, :finished, :success, :failure

	def ===(task)
	    return unless task.kind_of?(Roby::Task)
	    if model
		return unless model === task
	    end
	    if arguments
		return unless task.arguments.slice(*arguments.keys) == arguments
	    end
	    return unless improved_information.all? { |info| task.improves?(info) }
	    return unless needed_information.all?   { |info| task.needs?(info) }
	    return unless predicates.all? { |pred| task.send(pred) }
	    return if !owners.empty? && !task.owners.subset?(owners)
	    true
	end

	def each(plan)
	    plan.each_matching_task(self) { |task| yield(task) }
	    self
	end

	# Define singleton classes. For instance, calling Query.which_fullfills is equivalent
	# to Query.new.which_fullfills
	declare_class_methods :which_fullfills, :with_model, :with_arguments, :which_needs, :which_improves, :owned_by, :self_owned

	def negate; NegateTaskMatcher.new(self) end
	def &(other); AndTaskMatcher.new(self, other) end
	def |(other); OrTaskMatcher.new(self, other) end
    end

    class OrTaskMatcher < TaskMatcher
	def initialize(*ops)
	    @ops = ops 
	    super()
	end
	def <<(op); @ops << op end
	def ===(task)
	    return unless @ops.any? { |op| op === task }
	    super
	end
    end

    class NegateTaskMatcher < TaskMatcher
	def initialize(op)
	    @op = op
	    super()
       	end
	def ===(task)
	    return if @op === task
	    super
	end
    end

    class AndTaskMatcher < TaskMatcher
	def initialize(*ops)
	    @ops = ops 
	    super()
	end
	def ===(task)
	    return unless @ops.all? { |op| op === task }
	    super
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

