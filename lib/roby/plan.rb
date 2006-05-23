require 'set'
require 'roby/relations/hierarchy'

module Roby
    class Plan
	def initialize
	    @tasks = Set.new
	end

	# Merge +plan+ into this one
	def merge(plan)
	    plan.each_task { |task| @tasks << task }
	end

	def each_task(&iterator)
	    tasks.each(&iterator)
	end

	# List all tasks in the plan
	def tasks
	    tasks	= Set.new
	    new_tasks	= @tasks.dup
	    events	= Set.new
	    new_events	= Set.new
	    class << new_events # Make the 'events' set look like a relation node
		alias :each_related_object :each 
	    end

	    while task = new_tasks.find { true }
		task.enum_bfs(:each_related_object) do |t|
		    if t.kind_of?(Task) && !tasks.include?(t)
			tasks << t
			new_events.merge t.enum_for(:each_event).to_set
		    end
		end

		new_tasks.merge	new_events.enum_bfs(:each_related_object).
		    find_all { |ev| !events.include?(ev) && ev.respond_to?(:task) }.
		    each { |ev| events << ev }.
		    map  { |ev| ev.task }.
		    to_set

		new_events.clear
		new_tasks.delete(task)
		tasks << task
	    end

	    tasks
	end

        def display(g)
	    each_task do |task, _|
		task.each_event(false) do |event|
		    g.event_relation(EventStructure::CausalLinks, event)
		end
		g.task_relation(TaskStructure::Hierarchy, task, "color" => "red")
	    end
        end

        def insert(task)
	    @tasks << task
	    @first_task = task
	end
	attr_reader :first_task
	def start!(context)
	    first_task.start!(context)
	end
	alias :<< :insert
    end
end

