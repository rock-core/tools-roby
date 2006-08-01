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

	def each_task
	    tasks.each { |t| yield(t) }
	end
	
	# List all tasks in the plan
	def tasks
	    known_tasks	    = @tasks.dup # the list of already known tasks
	    all_tasks	    = Set.new # the target set
	    related_tasks   = Set.new
	    events	    = Array.new

	    while task = known_tasks.find { true }
		known_tasks.delete(task)
		raise if all_tasks.include?(task)
		all_tasks << task

		related_tasks.clear

		task.each_parent_object { |related| related_tasks << related if related.kind_of?(Task) }
		task.each_child_object { |related| related_tasks << related if related.kind_of?(Task) }

		events.clear

		task.each_event do |ev|
		    ev.each_parent_object do |related|
			next unless related.kind_of?(EventGenerator)
			if related.respond_to?(:task); related_tasks << related.task
			else; events << related
			end
		    end
		    ev.each_child_object do |related|
			next unless related.kind_of?(EventGenerator)
			if related.respond_to?(:task); related_tasks << related.task
			else; events << related
			end
		    end
		end
		events.each do |ev|
		    ev.each_parent_object do |related|
			next unless related.kind_of?(EventGenerator)
			if related.respond_to?(:task); related_tasks << related.task
			else; events << related
			end
		    end
		    ev.each_child_object do |related|
			next unless related.kind_of?(EventGenerator)
			if related.respond_to?(:task); related_tasks << related.task
			else; events << related
			end
		    end
		end

		related_tasks.each do |related|
		    next if all_tasks.include?(related)
		    known_tasks << related
		end
	    end

	    @tasks = all_tasks
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

	def find_tasks
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
	    plan ||= @plan
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

