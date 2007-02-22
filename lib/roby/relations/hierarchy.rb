require 'roby/task'
require 'roby/control'
require 'set'

module Roby::TaskStructure
    relation :Hierarchy, :child_name => :child, :parent_name => :parent_task do
	def realizes?(obj);	parent_object?(obj, Hierarchy) end
	def realized_by?(obj);  child_object?(obj, Hierarchy) end

	# Adds +task+ as a child of +self+. The following options are allowed:
	# success:: the list of success events
	# failure:: the list of failing event
	# model:: a [task_model, arguments] pair which defines the task model the
	#	  parent is expecting
        def realized_by(task, options = {})
            options = validate_options options, :model => [task.model, {}], :success => [:success], :failure => [:failed]

	    # Validate failure and success event names
	    options[:success] = Array[*options[:success]].each { |ev| task.event(ev) }
	    options[:failure] = Array[*options[:failure]].each { |ev| task.event(ev) }

	    options[:model] = [options[:model], {}] unless Array === options[:model]
	    if !task.fullfills?(*options[:model])
		raise ArgumentError, "task #{task} does not fullfills the provided model #{options[:model]}"
	    end

	    add_child(task, options)
            self
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

	# Return the model this task is fullfilling
	def fullfilled_model
	    model, arguments = Roby::Task, {}

	    each_parent_task do |parent|
		m, a = parent[self, Hierarchy][:model]
		if m < model
		    model = m
		elsif !(model < m) && model != m
		    raise "inconsistency in fullfilled models"
		end
		a.merge!(arguments) { |old, new| raise "inconsistency in fullfilled models" if old != new }
	    end

	    [model, arguments]
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

    # Checks the structure of +plan+. It returns an array of ChildFailedError
    # for all failed hierarchy relations
    def Hierarchy.check_structure(plan)
	result = []

	plan.known_tasks.each do |parent|
	    next if parent.finished? || parent.finishing?
	    parent.each_child do |child, options|
		success = options[:success]
		failure = options[:failure]

		next if success.any? { |e| child.event(e).happened? }
		if failing_event = failure.find { |e| child.event(e).happened? }
		    result << Roby::ChildFailedError.new(parent, child, child.event(failing_event).last)
		end
	    end
	end

	result
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

