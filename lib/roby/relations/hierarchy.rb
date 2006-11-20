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
            options = validate_options options, :model => [task.class, {}], :success => [:success], :failure => [:failed]

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

	    directed_component(Hierarchy).each do |task|
		next if task == self
		if task.event(:start).root?(Roby::EventStructure::CausalLink)
		    result << task
		end
	    end
	    result
        end

	# The set of events that are needed by the parent tasks
	def fullfilled_events
	    needed = Set.new
	    each_parent_task do |parent|
		needed |= parent[self, Hierarchy][:success]
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
    end

    class ChildFailedError < Roby::TaskModelViolation; end

    # Checks the structure of +plan+. It returns an array of ChildFailedError
    # for all failed hierarchy relations
    def Hierarchy.check_structure(plan)
	result = []

	plan.known_tasks.each do |parent|
	    next if parent.finished?
	    parent.each_child do |child, options|
		success = options[:success]
		failure = options[:failure]

		next if success.any? { |e| child.event(e).happened? }
		if failure.any? { |e| child.event(e).happened? }
		    result << ChildFailedError.new(child)
		end
	    end
	end

	result
    end

    Roby::Control.structure_checks << Hierarchy.method(:check_structure)
end

