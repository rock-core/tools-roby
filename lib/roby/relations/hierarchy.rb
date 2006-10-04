require 'enumerator'
require 'roby/relations'
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

	    options[:success] = Array[*options[:success]].map { |ev| task.event(ev) }
	    options[:failure] = Array[*options[:failure]].map { |ev| task.event(ev) }

	    options[:model] = [options[:model], {}] unless Array === options[:model]
	    if !task.fullfills?(*options[:model])
		raise ArgumentError, "task #{task} does not fullfills the provided model #{options[:model].inspect}"
	    end

	    add_child(task, options)
	    plan.discover(task) if plan
            self
        end

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

    protected
        attr_reader :realizes
    end
end

