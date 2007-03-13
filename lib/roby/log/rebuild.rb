require 'roby/distributed/protocol'
require 'roby/log/data_source'

module Roby
    module Log
	def self.update_marshalled(object_set, marshalled)
	    if old = object_set[marshalled.remote_object]
		marshalled.copy_from(old)
		Kernel.swap!(old, marshalled)
		old.instance_variable_set("@__bgl_graphs__", marshalled.instance_variable_get("@__bgl_graphs__"))
		old
	    else
		object_set[marshalled.remote_object] = marshalled
	    end
	end

	class Distributed::MarshalledPlanObject
	    include DirectedRelationSupport
	    def copy_from(old); end
	end
	class Distributed::MarshalledEventGenerator
	    def copy_from(old); end
	end
	class Distributed::MarshalledTaskEventGenerator
	    attr_writer :plan
	    attr_writer :task
	end
	class Distributed::MarshalledTask
	    def events
		@events ||= ValueSet.new
	    end

	    def copy_from(old)
		super
		@events = old.events
	    end

	    def to_s
		"#{model.name}:0x#{Object.address_from_id(remote_object.__drbref).to_s(16)}"
	    end

	end

	class Distributed::MarshalledRemoteTransactionProxy
	    include DirectedRelationSupport
	    def events; [] end
	    def copy_from(old); end
	end

	class Plan
	    attr_reader   :remote_object
	    attr_reader   :missions, :known_tasks, :free_events
	    attr_reader   :transactions
	    attr_accessor :root_plan
	    def initialize(remote_object)
		@root_plan    = true
		@remote_object = remote_object
		@missions     = ValueSet.new
		@known_tasks  = ValueSet.new
		@free_events  = ValueSet.new
		@transactions = ValueSet.new
	    end

	    def clear
		transactions.dup.each do |trsc|
		    trsc.clear
		    removed_transaction(trsc)
		end
		known_tasks.dup.each { |t| finalized_task(t) }
		free_events.dup.each { |e| finalized_event(e) }
	    end

	    def finalized_task(task)
		missions.delete(task)
		known_tasks.delete(task)
		task.clear_vertex
	    end
	    def finalized_event(event)
		free_events.delete(event)
		event.clear_vertex
	    end
	    def removed_transaction(trsc)
		transactions.delete(trsc)
	    end
	end

	# This class is a logger-compatible interface which rebuilds the task and event
	# graphs from the marshalled events that are saved using for instance FileLogger
	class PlanRebuild < DataSource
	    def splat?; true end
	    attr_reader :plans
	    attr_reader :tasks
	    attr_reader :events

	    attr_reader :io
	    attr_reader :next_step
	    attr_reader :displays
	    attr_reader :range

	    def initialize(filename)
		@io     = Roby::Log.open(filename)
		super([filename], 'roby-events')
		@plans  = Hash.new
		@tasks  = Hash.new
		@events = Hash.new
		@next_step = Array.new
		@range = [nil, nil]

		prepare_seek(nil)
		while next_step.size == 1
		    read_step
		end
	    end
	    def clear
		super

		plans.each { |p| p.clear }
		plans.clear
		tasks.clear
		events.clear
	    end
	    
	    def prepare_seek(time)
		if !time || time < current_time
		    clear
		    io.rewind
		    read_step

		    range[0] = current_time
		    range[1] ||= current_time
		end
	    end
	    
	    # Replays one cycle
	    def read_step
		next_step.clear
		return if io.eof?
		FileLogger.replay(io) do |method_name, method_args|
		    next_step << [method_name, method_args]
		    if method_name == :cycle_end
			break
		    end
		end

		range[1] = next_step_time if range[1] && range[1] < next_step_time
	    rescue EOFError
	    end
	    
	    def current_time;  next_step.first[1][0] unless next_step.empty? end
	    def next_step_time
		next_step.last[1][0] unless next_step.empty? 
	    end
	    def advance
		next_step.each do |name, args|
		    send(name, *args) if respond_to?(name)
		    displays.each { |d| d.send(name, *args) if d.respond_to?(name) }
		end
		read_step
	    end

	    def local_plan(plan)
		return unless plan
		@plans[plan.remote_object] ||= Plan.new(plan.remote_object)
	    end

	    def local_object(set, marshalled)
		marshalled = Log.update_marshalled(set, marshalled)
		plan = if marshalled.respond_to?(:transaction)
			   local_plan(marshalled.transaction)
		       else
			   local_plan(marshalled.plan)
		       end
		if plan
		    yield(plan) if block_given?
		end
		marshalled
	    end

	    def local_task(task); local_object(tasks, task) end
	    def local_event(event)
		if event.respond_to?(:task)
		    task = local_task(event.task)
		    event.task = task
		    event.plan = task.plan
		    event = local_object(events, event)
		    task.events << event
		    event
		else
		    local_object(events, event) 
		end
	    end
	    def inserted_tasks(time, plan, task)
		local_plan(plan).missions << task.remote_object
	    end
	    def discarded_tasks(time, plan, task)
		local_plan(plan).missions.delete(task.remote_object)
	    end
	    def replaced_tasks(time, plan, from, to)
	    end
	    def discovered_events(time, plan, events)
		plan = local_plan(plan)
		events.each { |ev| plan.free_events << local_event(ev) }
	    end
	    def discovered_tasks(time, plan, tasks)
		plan = local_plan(plan)
		tasks.each { |t| plan.known_tasks << local_task(t) }
	    end
	    def garbage_task(time, plan, task)
	    end
	    def finalized_event(time, plan, event)
		event = local_event(event)
		local_plan(plan).finalized_event(event)
		events.delete(event.remote_object)
	    end
	    def finalized_task(time, plan, task)
		task = local_task(task)
		local_plan(plan).finalized_task(task)
		tasks.delete(task.remote_object)
	    end
	    def added_transaction(time, plan, trsc)
		plan = local_plan(plan)
		trsc = local_plan(trsc)
		plan.transactions << trsc
		trsc.root_plan = false
	    end
	    def removed_transaction(time, plan, trsc)
		plan = local_plan(plan)
		trsc = local_plan(trsc)
		plans.delete(trsc.remote_object)

		plan.transactions.delete(trsc)
		# Removed tasks and proxies that have been moved from the
		# transaction to the plan before clearing the transaction
		plan.known_tasks.each do |obj|
		    trsc.known_tasks.delete(obj)
		end
		plan.free_events.each do |obj|
		    trsc.free_events.delete(obj)
		end
		trsc.clear
	    end

	    def added_task_child(time, parent, rel, child, info)
		parent = local_task(parent)
		child  = local_task(child)
		parent.add_child_object(child, rel, [info, nil])
	    end
	    def removed_task_child(time, parent, rel, child)
		parent = local_task(parent)
		child  = local_task(child)
		parent.remove_child_object(child, rel)
	    end
	    def added_event_child(time, parent, rel, child, info)
		parent = local_event(parent)
		child  = local_event(child)
		parent.add_child_object(child, rel, [info, nil])
	    end
	    def removed_event_child(time, parent, rel, child)
		parent = local_event(parent)
		child  = local_event(child)
		parent.remove_child_object(child, rel)
	    end

	end
    end
end
