require 'roby/task'
require 'roby/control'
require 'set'

module Roby::TaskStructure
    # Document-module: Hierarchy
    relation :Hierarchy, :child_name => :child, :parent_name => :parent_task do
	# True if +obj+ is a parent of this object in the hierarchy relation
	# (+obj+ is realized by +self+)
	def realizes?(obj);	parent_object?(obj, Hierarchy) end
	# True if +obj+ is a child of this object in the hierarchy relation
	def realized_by?(obj);  child_object?(obj, Hierarchy) end
	# True if +obj+ can be reached through the Hierarchy relation by
	# starting from this object
	def depends_on?(obj)
	    generated_subgraph(Hierarchy).include?(obj)
	end
	# The set of parent objects in the Hierarchy relation
	def parents; parent_objects(Hierarchy) end
	# The set of child objects in the Hierarchy relation
	def children; child_objects(Hierarchy) end


	# Adds +task+ as a child of +self+ in the Hierarchy relation. The
	# following options are allowed:
	#
	# success:: the list of success events. The default is [:success]
	# failure:: the list of failing events. The default is [:failed]
	# model:: a <tt>[task_model, arguments]</tt> pair which defines the task model the parent is expecting. 
	#   The default value is to get these parameters from +task+
        def realized_by(task, options = {})
            options = validate_options options, 
		:model => [task.model, task.meaningful_arguments], 
		:success => [:success], 
		:failure => [:failed],
		:remove_when_done => false

	    options[:success] = Array[*options[:success]]
	    options[:failure] = Array[*options[:failure]]

	    # Validate failure and success event names
	    options[:success].each { |ev| task.event(ev) }
	    options[:failure].each { |ev| task.event(ev) }

	    options[:model] = [options[:model], {}] unless Array === options[:model]
	    required_model, required_args = *options[:model]
	    if !task.fullfills?(required_model, required_args)
		raise ArgumentError, "task #{task} does not fullfills the provided model #{options[:model]}"
	    end

	    add_child(task, options)
            self
        end

	# Set up the event gathering needed by Hierarchy.check_structure
	def added_child_object(child, relations, info) # :nodoc:
	    super if defined? super
	    if relations.include?(Hierarchy) && !respond_to?(:__getobj__) && !child.respond_to?(:__getobj__)
		events = info[:success].map { |ev| child.event(ev) }
		events.concat info[:failure].map { |ev| child.event(ev) }
		Roby::EventGenerator.gather_events(Hierarchy.interesting_events, events)
	    end
	end

	# Return the set of this task children for which the :start event has
	# no parent in CausalLinks
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

	# Return [tags, arguments] where +tags+ is a list of task models which
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

    # Checks the structure of +plan+ w.r.t. the constraints of the hierarchy
    # relations. It returns an array of ChildFailedError for all failed
    # hierarchy relations
    def Hierarchy.check_structure(plan)
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
		next unless parent.self_owned?
		next if parent.finished? || parent.finishing?

		options = parent[child, Hierarchy]
		success = options[:success]
		failure = options[:failure]

		if success.any? { |e| child.event(e).happened? }
		    if options[:remove_when_done]
			parent.remove_child child
		    end
		elsif failing_event = failure.find { |e| child.event(e).happened? }
		    result << Roby::ChildFailedError.new(parent, child.event(failing_event).last)
		    failing_tasks << child
		end
	    end
	end

	events.clear
	result
    end

    class << Hierarchy
	# The set of events that have been fired in this cycle and are involved in a Hierarchy relation
	attribute(:interesting_events) { Array.new }

	# The set of tasks that are currently failing 
	attribute(:failing_tasks) { ValueSet.new }
    end
end

module Roby
    # This exception is raised when a {hierarchy relation}[classes/Roby/TaskStructure/Hierarchy.html] fails
    class ChildFailedError < LocalizedError
	# The parent in the relation
	attr_reader :parent
	# The child in the relation
	def child; failed_task end
	# The relation parameters (i.e. the hash given to #realized_by)
	attr_reader :relation

	# The event which is the cause of this error. This is either the task
	# source of a failure event, or the reason why a positive event has
	# become unreachable (if there is one)

	def initialize(parent, event)
	    super(event.task_sources.find { true })
	    @parent = parent
	    @relation = parent[child, TaskStructure::Hierarchy]
	end

	def message # :nodoc:
	    "#{super}\nthe failed relation is: #{parent}\n        realized_by\n    #{child}"
	end

	def backtrace; [] end
    end
    Control.structure_checks << TaskStructure::Hierarchy.method(:check_structure)
end

