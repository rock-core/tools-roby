require 'roby/distributed/protocol'
require 'roby/log/data_stream'
require 'stringio'

module Roby
    class PlanObject::DRoby
	include DirectedRelationSupport
	attr_writer :plan

	def update_from(new)
	    super if defined? super
       	end
    end
    class TaskEventGenerator::DRoby
	include DirectedRelationSupport
	attr_writer :plan
	attr_writer :task

	def update_from(new)
	    super if defined? super
       	end
    end
    class Task::DRoby
	attr_writer :plan
	attribute(:events) { Hash.new }

	def update_from(new)
	    super if defined? super
	    self.flags.merge! new.flags
	    self.plan  = new.plan
	end
    end

    class Transaction::Proxy::DRoby
	include DirectedRelationSupport
	attr_writer :transaction
	attr_accessor :plan

	def events; Hash.new end

	def update_from(new)
	    super if defined? super
       	end
    end

    module LoggedPlan
	attribute(:missions)	 { ValueSet.new }
	attribute(:known_tasks)  { ValueSet.new }
	attribute(:free_events)  { ValueSet.new }
	attribute(:transactions) { ValueSet.new }
	attribute(:finalized_tasks)  { ValueSet.new }
	attribute(:finalized_events) { ValueSet.new }
	attr_accessor :parent_plan

	def root_plan?; !parent_plan end
	def update_from(new); end
	def clear
	    transactions.dup.each do |trsc|
		trsc.clear
		removed_transaction(trsc)
	    end
	    known_tasks.dup.each { |t| finalized_task(t) }
	    free_events.dup.each { |e| finalized_event(e) }
	    clear_finalized
	end

	def finalized_task(task)
	    missions.delete(task)
	    known_tasks.delete(task)
	    finalized_tasks << task
	end
	def finalized_event(event)
	    free_events.delete(event)
	    finalized_events << event unless event.respond_to?(:task)
	end
	def clear_finalized
	    finalized_tasks.each { |task| task.clear_vertex }
	    finalized_tasks.clear
	    finalized_events.each { |event| event.clear_vertex }
	    finalized_events.clear
	end
	def removed_transaction(trsc)
	    transactions.delete(trsc)
	end
    end

    class Plan::DRoby
	include LoggedPlan
    end

    class Distributed::Transaction::DRoby
	include LoggedPlan
	attr_writer :plan
    end

    module Log
	class << self
	    # Register all siblings to do some cleanup when the object is finally removed
	    attribute(:all_siblings) { Hash.new }
	end

	def self.local_object(object_set, marshalled)
	    old = marshalled.remote_siblings.find do |peer, id| 
		raise "problem with remote_siblings: #{marshalled.remote_siblings}" unless peer && id
		all_siblings.has_key?(id)
	    end

	    object = if old
			 peer, id = *old
			 update_object(all_siblings[id], marshalled)
		     else
			 marshalled
		     end


	    marshalled.remote_siblings.each do |_, id|
		all_siblings[id] = object
		object_set[object] << id
	    end

	    raise unless object
	    object
	end

	def self.update_object(old, new)
	    old.update_from(new)
	    old # roles have been swapped between old and new
	end

	def self.remove_object(object_set, object)
	    id = if object.kind_of?(Distributed::RemoteID)
		     object
		 elsif object.respond_to?(:remote_siblings)
		     object_id = object.remote_siblings.enum_for.
			 find { |peer, id| all_siblings[id] }

		     unless object_id
			 raise "unknown object #{object_id || 'nil'}"
		     end
		     object_id.last
		 end

	    if id
		object = all_siblings.delete(id)
		object_set.delete(object).each do |id|
		    all_siblings.delete(id)
		end
	    else
		object_set.delete(object)
	    end
	end
	
	# This class rebuilds a plan-like structure from events saved by a
	# FileLogger object This is compatible with the EventStream data source
	class PlanRebuilder < DataDecoder
	    attr_reader :plans
	    attr_reader :tasks
	    attr_reader :events

	    def initialize
		@plans  = Hash.new { |h, k| h[k] = Set.new }
		@tasks  = Hash.new { |h, k| h[k] = Set.new }
		@events = Hash.new { |h, k| h[k] = Set.new }
		super
	    end

	    def clear
		Log.all_siblings.clear
		super

		plans.dup.each { |p| p.clear if p.root_plan? }
		plans.clear
		tasks.clear
		events.clear
	    end

	    def rewind
		clear
	    end
	    
	    def process(data)
		data.each_slice(2) do |m, args|
		    reason = catch :ignored do
			begin
			    if respond_to?(m)
				send(m, *args)
			    end
			    displays.each { |d| d.send(m, *args) if d.respond_to?(m) }
			rescue Exception => e
			    display_args = args.map do |obj|
				case obj
				when NilClass: 'nil'
				when Time: obj.to_hms
				when DRbObject: obj.inspect
				else (obj.to_s rescue "failed_to_s")
				end
			    end

			    raise e, "#{e.message} while serving #{m}(#{display_args.join(", ")})", e.backtrace
			end
			nil
		    end
		    if reason
			Roby.warn "Ignored #{m}(#{args.join(", ")}): #{reason}"
		    end
		end
	    end

	    def local_object(set, object)
		return nil unless object

		object = if !object.kind_of?(Distributed::RemoteID)
			     Log.local_object(set, object)
			 else
			     Log.all_siblings[object]
			 end

		plan = if object.respond_to?(:transaction)
			   object.transaction = local_plan(object.transaction)
			   object.plan = object.transaction
		       elsif object.respond_to?(:plan)
			   object.plan = local_plan(object.plan)
		       end

		if plan
		    yield(plan) if block_given?
		end
		object
	    end

	    def display
		super
		
		plans.each_key do |plan|
		    plan.clear_finalized
		end
	    end

	    def local_plan(plan); local_object(plans, plan) end
	    def local_task(task); local_object(tasks, task) end
	    def local_event(event)
		if event.respond_to?(:task)
		    task = local_task(event.task)
		    event.task = task
		    event.plan = task.plan
		    event = if old = task.events[event.symbol]
				Log.update_object(old, event)
			    else
				task.events[event.symbol] = event
			    end

		    events[event] = nil
		    event
		else
		    local_object(events, event) 
		end
	    end

	    def inserted_tasks(time, plan, task)
		plan = local_plan(plan)
		plan.missions << task
	    end
	    def discarded_tasks(time, plan, task)
		plan = local_plan(plan)
		plan.missions.delete(task)
	    end
	    def replaced_tasks(time, plan, from, to)
	    end
	    def discovered_events(time, plan, events)
		plan = local_plan(plan)
		events.each do |ev| 
		    ev = local_event(ev)
		    plan.free_events << ev
		    finalized_events.delete(ev)
		end
	    end
	    def discovered_tasks(time, plan, tasks)
		plan = local_plan(plan)
		tasks.each do |t| 
		    t = local_task(t)
		    plan.known_tasks << t
		    plan.transactions.each do |t|
			plan.finalized_tasks.delete(t)
		    end
		end
	    end
	    def garbage_task(time, plan, task)
	    end
	    def finalized_event(time, plan, event)
		event = local_event(event)
		plan  = local_plan(plan)

		unless event.respond_to?(:task) || plan.parent_plan && plan.parent_plan.free_events.include?(event)
		    plan.finalized_event(event)
		    Log.remove_object(events, event)
		end
	    end
	    def finalized_task(time, plan, task)
		task = local_task(task)
		throw :ignored, "unknown task" unless task

		plan = local_plan(plan)
		plan.finalized_task(task)
		Log.remove_object(tasks, task)
	    end
	    def added_transaction(time, plan, trsc)
		plan = local_plan(plan)
		trsc = local_plan(trsc)
		plan.transactions << trsc
		trsc.parent_plan  = plan
	    end
	    def removed_transaction(time, plan, trsc)
		plan = local_plan(plan)
		trsc = local_plan(trsc)

		(trsc.known_tasks - plan.known_tasks).each do |obj|
		    trsc.finalized_task(obj)
		end
		(trsc.free_events - plan.free_events).each do |obj|
		    trsc.finalized_event(obj)
		end

		trsc.clear_finalized
		Log.remove_object(plans, trsc)
		plan.transactions.delete(trsc)
	    end

	    def added_task_child(time, parent, rel, child, info)
		parent = local_task(parent)
		child  = local_task(child)
		if !parent   then throw :ignored, "unknown parent"
		elsif !child then throw :ignored, "unknown child"
		end

		rel    = rel.proxy(nil)
		parent.add_child_object(child, rel, [info, nil])
	    end
	    def removed_task_child(time, parent, rel, child)
		parent = local_task(parent)
		child  = local_task(child)
		rel    = rel.proxy(nil)
		parent.remove_child_object(child, rel)
	    end
	    def added_event_child(time, parent, rel, child, info)
		parent = local_event(parent)
		child  = local_event(child)
		rel    = rel.proxy(nil)
		parent.add_child_object(child, rel, [info, nil])
	    end
	    def removed_event_child(time, parent, rel, child)
		parent = local_event(parent)
		child  = local_event(child)
		rel    = rel.proxy(nil)
		parent.remove_child_object(child, rel)
	    end
	end

    end
end

