require 'roby/plan'
require 'roby/transactions'
require 'roby/state/information'

module Roby
    # The query class represents a search in a plan. 
    # It can be used locally on any Plan object, but 
    # is mainly used as an argument to DRb::Server#find
    class TaskMatcher
	attr_reader :model, :arguments
	attr_reader :predicates, :neg_predicates, :owners

	attr_reader :improved_information
	attr_reader :needed_information

	def initialize
	    @predicates           = ValueSet.new
	    @neg_predicates       = ValueSet.new
	    @owners               = Array.new
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
	    improved_information.merge(info.to_value_set)
	    self
	end

	# find tasks which need information contained in +info+
	def which_needs(*info)
	    needed_information.merge(info.to_value_set)
	    self
	end

	def owned_by(*ids)
	    @owners |= ids
	    self
	end
	def self_owned
	    owned_by(Roby::Distributed)
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
			if neg_predicates.include?(:#{name}?)
			    raise ArgumentError, "trying to match (#{name}? & !#{name}?)"
		        end
			predicates << :#{name}?
			self
		    end
		    def not_#{name}
			if predicates.include?(:#{name}?)
			    raise ArgumentError, "trying to match (#{name}? & !#{name}?)"
		        end
			neg_predicates << :#{name}?
			self
		    end
		    EOD
		end
		declare_class_methods(*names)
		declare_class_methods(*names.map { |n| "not_#{n}" })
	    end
	end
	match_predicates :executable, :abstract, :partially_instanciated, :fully_instanciated,
	    :pending, :running, :finished, :success, :failure

	def ===(task)
	    return unless task.kind_of?(Roby::Task)
	    if model
		return unless task.fullfills?(model)
	    end
	    if arguments
		return unless task.arguments.slice(*arguments.keys) == arguments
	    end
	    return unless improved_information.all? { |info| task.improves?(info) }
	    return unless needed_information.all?   { |info| task.needs?(info) }
	    return unless predicates.all? { |pred| task.send(pred) }
	    return if neg_predicates.any? { |pred| task.send(pred) }
	    return if !owners.empty? && !(task.owners - owners).empty?
	    true
	end

	def each(plan, &block)
	    plan.query_each(plan.query_result_set(self), &block)
	    self
	end

	# Define singleton classes. For instance, calling Query.which_fullfills is equivalent
	# to Query.new.which_fullfills
	declare_class_methods :which_fullfills, 
	    :with_model, :with_arguments, 
	    :which_needs, :which_improves, 
	    :owned_by, :self_owned

	def negate; NegateTaskMatcher.new(self) end
	def &(other); AndTaskMatcher.new(self, other) end
	def |(other); OrTaskMatcher.new(self, other) end
    end

    class Query < TaskMatcher
	attr_reader :plan
	def initialize(plan)
	    @plan = plan
	    super()
	    @plan_predicates = Array.new
	    @neg_plan_predicates = Array.new
	end

	def result_set
	    @result_set ||= plan.query_result_set(self)
	end

	attr_reader :plan_predicates
	attr_reader :neg_plan_predicates
	class << self
	    def match_plan_predicates(*names)
		names.each do |name|
		    class_eval <<-EOD
		    def #{name}
			if neg_plan_predicates.include?(:#{name}?)
			    raise ArgumentError, "trying to match (#{name}? & !#{name}?)"
		        end
			plan_predicates << :#{name}?
			self
		    end
		    def not_#{name}
			if plan_predicates.include?(:#{name}?)
			    raise ArgumentError, "trying to match (#{name}? & !#{name}?)"
		        end
			neg_plan_predicates << :#{name}?
			self
		    end
		    EOD
		end
	    end
	end
	match_plan_predicates :mission, :permanent
	
	# Returns the set of tasks from the query for which no parent in
	# +relation+ can be found in the query itself
	def roots(relation)
	    @result_set = plan.query_roots(result_set, relation)
	    self
	end

	def ===(task)
	    return unless super
	    return unless plan_predicates.all? { |pred| plan.send(pred, task) }
	    return if neg_plan_predicates.any? { |pred| plan.send(pred, task) }
	    true
	end

	def each(&block)
	    plan.query_each(result_set, &block)
	    self
	end
	include Enumerable
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

    class Plan
	# Returns a Query object on this plan
	def find_tasks
	    Query.new(self)
	end

	# Called by TaskMatcher#result_set and Query#result_set to get the set
	# of tasks matching +matcher+
	def query_result_set(matcher)
	    @known_tasks.find_all { |t| matcher === t }
	end

	# Called by TaskMatcher#each and Query#each to return the result of
	# this query on +self+
	def query_each(result_set, &block)
	    result_set.each(&block)
	end

	# Given the result set of +query+, returns the subset of tasks which
	# have no parent in +query+
	def query_roots(result_set, relation)
	    children = ValueSet.new
	    found    = ValueSet.new
	    result_set.each do |task|
		next if children.include?(task)
		task_children = task.generated_subgraph(relation)
		found -= task_children
		children.merge(task_children)
		found << task
	    end
	    found
	end
    end

    class Transaction
	# Returns two sets of tasks, [plan, transaction]. The union of the two
	# is the component that would be returned by
	# +relation.generated_subgraphs(*seeds)+ if the transaction was
	# committed
	def merged_generated_subgraphs(relation, plan_seeds, transaction_seeds)
	    plan_set        = ValueSet.new
	    transaction_set = ValueSet.new
	    plan_seeds	      = plan_seeds.to_value_set
	    transaction_seeds = transaction_seeds.to_value_set

	    loop do
		old_transaction_set = transaction_set.dup
		transaction_set.merge(transaction_seeds)
		relation.generated_subgraphs(transaction_seeds.to_a, false).
		    inject(transaction_set) do |transaction_set, new_set| 
			transaction_set.merge(new_set)
		    end

		if old_transaction_set.size != transaction_set.size
		    (transaction_set - old_transaction_set).each do |o| 
			if o.respond_to?(:__getobj__)
			    o.__getobj__.each_child_object(relation) do |child|
				plan_seeds << child unless self[child, false]
			    end
			end
		    end
		end
		transaction_seeds.clear

		plan_set.merge(plan_seeds)
		plan_seeds.each do |seed|
		    relation.each_dfs(seed, BGL::Graph::TREE) do |_, dest, _, kind|
			next if plan_set.include?(dest)
			if self[dest, false]
			    proxy = wrap(dest, false)
			    unless transaction_set.include?(proxy)
				transaction_seeds << proxy
			    end
			    relation.prune # transaction branches must be developed inside the transaction
			else
			    plan_set << dest
			end
		    end
		end
		break if transaction_seeds.empty?

		plan_seeds.clear
	    end

	    [plan_set, transaction_set]
	end
	
	# Returns [plan_set, transaction_set], where the first is the set of
	# plan tasks matching +matcher+ and the second the set of transaction
	# tasks matching it. The two sets are disjoint.
	def query_result_set(matcher)
	    plan_set, transaction_set = ValueSet.new, ValueSet.new
	    plan.query_result_set(matcher).each do |task|
		plan_set << task unless self[task, false]
	    end
	    super.each do |task|
		transaction_set << task if self[task, false]
	    end

	    [plan_set, transaction_set]
	end

	# Yields tasks in the result set of +query+. Unlike Query#result_set,
	# all the tasks are included in the transaction
	def query_each(result_set)
	    plan_set, trsc_set = result_set
	    plan_set.each { |task| yield(self[task]) }
	    trsc_set.each { |task| yield(task) }
	end

	# Given the result set of +query+, returns the subset of tasks which
	# have no parent in +query+
	def query_roots(result_set, relation)
	    plan_set      , trsc_set      = *result_set
	    plan_result   , trsc_result   = ValueSet.new     , ValueSet.new
	    plan_children , trsc_children = ValueSet.new     , ValueSet.new

	    plan_set.each do |task|
		next if plan_children.include?(task)
		task_plan_children, task_trsc_children = 
		    merged_generated_subgraphs(relation, [task], [])

		plan_result -= task_plan_children
		trsc_result -= task_trsc_children
		plan_children.merge(task_plan_children)
		trsc_children.merge(task_trsc_children)

		plan_result << task
	    end

	    trsc_set.each do |task|
		next if trsc_children.include?(task)
		task_plan_children, task_trsc_children = 
		    merged_generated_subgraphs(relation, [], [task])

		plan_result -= task_plan_children
		trsc_result -= task_trsc_children
		plan_children.merge(task_plan_children)
		trsc_children.merge(task_trsc_children)

		trsc_result << task
	    end

	    [plan_result, trsc_result]
	end
    end
end

