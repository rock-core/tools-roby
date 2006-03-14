require 'set'
require 'roby/relations/hierarchy'

module Roby
    class Plan
	attribute(:tasks) { Set.new }

        def insert(task)
	    events = Set.new
	    class << events # Make the 'events' set look like a relation node
		alias :each_related_object :each 
	    end
	    raise unless events.respond_to?(:each_related_object)

	    tasks << task
	    # Get all tasks
	    task.enum_bfs(:each_related_object) do |t, _|
		next unless t.kind_of? Task
		tasks << t
		events.merge t.enum_for(:each_event).to_set
	    end

	    # Propagate through the event network
	    events.enum_bfs(:each_related_object) do |ev, _|
		if TaskEventGenerator === ev
		    tasks << ev.task
		end
	    end
        end
	alias :<< :insert

	def has_task?(task); @tasks.include?(task) end
	def merge(plan)
	    plan.each_task { |task| @tasks << task }
	end
	def each_task(&iterator); @tasks.each(&iterator) end

        def display(g)
	    tasks.each do |task, _|
		task.each_event(false) do |event|
		    g.event_relation('causal', event, :each_causal_link)
		end
		g.task_relation('hierarchy', task, :each_child, "color" => "red")
	    end
        end
    end
end

