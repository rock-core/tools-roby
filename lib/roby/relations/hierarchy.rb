require 'roby/task'
require 'roby/control'
require 'set'

module Roby::TaskStructure
    relation :Hierarchy, :child_name => :child, :parent_name => :parent_task do
	def realizes?(obj);	parent_object?(obj, Hierarchy) end
	def realized_by?(obj);  child_object?(obj, Hierarchy) end
	def depends_on?(obj)
	    generated_subgraph(Hierarchy).include?(obj)
	end

	# Adds +task+ as a child of +self+. The following options are allowed:
	# success:: the list of success events
	# failure:: the list of failing event
	# model:: a [task_model, arguments] pair which defines the task model the
	#	  parent is expecting
        def realized_by(task, options = {})
            options = validate_options options, 
		:model => [task.model, task.meaningful_arguments], 
		:success => [:success], 
		:failure => [:failed]
	    options[:success] = Array[*options[:success]]
	    options[:failure] = Array[*options[:failure]]

	    # Validate failure and success event names
	    options[:success].each { |ev| task.event(ev) }
	    options[:failure].each { |ev| task.event(ev) }

	    options[:model] = [options[:model], {}] unless Array === options[:model]
	    required_model, required_args = *options[:model]
	    unknown_args = (required_args.keys - required_model.arguments.to_a)
	    if !unknown_args.empty?
		raise ArgumentError, "the arguments '#{unknown_args.join(", ")}' are not meaningful to the #{required_model} model"
	    elsif !task.fullfills?(required_model, required_args)
		raise ArgumentError, "task #{task} does not fullfills the provided model #{options[:model]}"
	    end

	    add_child(task, options)
            self
        end

	def added_child_object(child, relation, info)
	    super if defined? super
	    if relation == Hierarchy
		events = info[:success].map { |ev| child.event(ev) }
		events.concat info[:failure].map { |ev| child.event(ev) }
		if !events.all? { |ev| ev.respond_to?(:task) }
		    raise
		end
		Roby::EventGenerator.gather_events(Hierarchy.interesting_events, *events)
	    end
	end

	def parents; parent_objects(Hierarchy) end
	def children; child_objects(Hierarchy) end

        # Return an array of the task for which the :start event is not
        # signalled by a child event
        def first_children
	    result = ValueSet.new

	    generated_subgraph(Hierarchy).each do |task|
		next if task == self
		if task.event(:start).root?(Roby::EventStructure::CausalLink)
		    result << task
		end
	    end
	    result
        end

	# The set of events that are needed by the parent tasks
	def fullfilled_events
	    needed = ValueSet.new
	    each_parent_task do |parent|
		needed.merge(parent[self, Hierarchy][:success])
	    end
	    needed
	end

	# Return [tags, argumetnts] where +tags+ is a list of task models which
	# are required by the parent tasks of this task, and arguments the
	# required arguments
	#
	# If there is a task class in the required models, it is always the
	# first element of +tags+
	def fullfilled_model
	    model, tags, arguments = Roby::Task, [], {}

	    each_parent_task do |parent|
		m, a = parent[self, Hierarchy][:model]
		if m.instance_of?(Roby::TaskModelTag)
		    tags << m
		elsif m.has_ancestor?(model)
		    model = m
		elsif !model.has_ancestor?(m)
		    raise "inconsistency in fullfilled models: #{model} and #{m} are incompatible"
		end
		a.merge!(arguments) do |old, new| 
		    if old != new
			raise "inconsistency in fullfilled models: #{old} and #{new}"
		    end
		end
	    end

	    tags.unshift(model)
	    [tags, arguments]
	end

	# Remove all children that have successfully finished
	def remove_finished_children
	    # We call #to_a to get a copy of children, since we will remove
	    # children in the block. Note that we can't use #delete_if here
	    # since #children is a relation enumerator (not the relation list
	    # itself)
	    children.to_a.each do |child|
		success_events = self[child, Hierarchy][:success]
		if success_events.any? { |ev| child.event(ev).happened? }
		    remove_child(child)
		end
	    end
	end
    end

    class << Hierarchy
	# Checks the structure of +plan+. It returns an array of ChildFailedError
	# for all failed hierarchy relations
	def check_structure(plan)
	    result = []

	    events = Hierarchy.interesting_events
	    return result if events.empty? && failing_tasks.empty?

	    # Get the set of tasks for which a possible failure has been
	    # registered The tasks that are failing the hierarchy requirements
	    # are registered in Hierarchy.failing_tasks. The interesting_events
	    # set is cleared at cycle end (see below)
	    tasks = events.inject(failing_tasks) { |set, event| set << event.generator.task }
	    @failing_tasks = ValueSet.new
	    tasks.each do |child|
		# Check if the task has been removed from the plan
		next unless child.plan

		has_error = false
		child.each_parent_task do |parent|
		    next if parent.finished? || parent.finishing?

		    options = parent[child, Hierarchy]
		    success = options[:success]
		    failure = options[:failure]

		    next if success.any? { |e| child.event(e).happened? }
		    if failing_event = failure.find { |e| child.event(e).happened? }
			result << Roby::ChildFailedError.new(parent, child, child.event(failing_event).last)
			failing_tasks << child
		    end
		end
	    end

	    events.clear
	    result
	end

	# The set of events that have been fired in this cycle and are involved in a Hierarchy relation
	attribute(:interesting_events) { Array.new }

	# The set of tasks that are currently failing 
	attribute(:failing_tasks) { ValueSet.new }
    end
end

module Roby
    class ChildFailedError < TaskModelViolation
	alias :child :task
	attr_reader :parent, :relation, :with
	def initialize(parent, child, with)
	    super(child)
	    @parent = parent
	    @relation = parent[child, TaskStructure::Hierarchy]
	    @with = with
	end
	def message
	    "#{parent}.realized_by(#{child}, #{relation}) failed with #{with.symbol}(#{with.context})\n#{super}"
	end
    end
    Control.structure_checks << TaskStructure::Hierarchy.method(:check_structure)
end

