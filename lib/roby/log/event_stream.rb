require 'roby/distributed/protocol'
require 'roby/log/data_stream'

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
	attribute(:missions) { ValueSet.new }
	attribute(:known_tasks) { ValueSet.new }
	attribute(:free_events) { ValueSet.new }
	attribute(:transactions) { ValueSet.new }
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
	

	# This class is a logger-compatible interface which read event and index logs,
	# and may rebuild the task and event graphs from the marshalled events
	# that are saved using for instance FileLogger
	class EventStream < DataStream
	    def splat?; true end

	    attr_reader :plans
	    attr_reader :tasks
	    attr_reader :events
	    attr_reader :finalized_tasks
	    attr_reader :finalized_events

	    # The IO object of the event log
	    attr_reader :event_log
	    # The IO object of the index log
	    attr_reader :index_log
	    # The data from +index_log+ loaded so far
	    attr_reader :index_data

	    # The index of the currently displayed cycle in +index_data+
	    attr_reader :current_cycle
	    # A [min, max] array of the minimum and maximum times for this
	    # stream
	    attr_reader :range

	    def initialize(basename)
		@event_log = Roby::Log.open("#{basename}-events.log")
		begin
		    @index_log  = File.open("#{basename}-index.log")
		rescue Errno::ENOENT
		    Roby.warn "rebuilding index file in #{basename}-index.log"
		    @index_log = File.open("#{basename}-index.log", "w+")
		    FileLogger.rebuild_index(@event_log, @index_log)
		end

		super(basename, 'roby-events')
		@plans  = Hash.new { |h, k| h[k] = Set.new }
		@tasks  = Hash.new { |h, k| h[k] = Set.new }
		@events = Hash.new { |h, k| h[k] = Set.new }
		@finalized_tasks  = Hash.new
		@finalized_events = Hash.new

		@current_cycle  = 0
		@index_data	= Array.new
		prepare_seek(nil)

		# Skip the empty cycles at the beginning of the log file
		while has_sample?
		    break unless read_step.size == 1
		end
	    end

	    def update_index
		# Read as much index data as possible
		begin
		    pos = nil
		    loop do
			pos = index_log.tell
			index_data << Marshal.load(index_log)
		    end
		rescue EOFError
		    index_log.seek(pos, IO::SEEK_SET)
		end

		return if index_data.empty?

		# Update range
		@range = [index_data.first[:start], index_data.last[:end]]
	    end

	    def has_sample?
		update_index
		!index_data.empty? && (index_data.last[:pos] > event_log.tell)
	    end

	    def clear
		Log.all_siblings.clear
		super

		plans.each { |p| p.clear }
		plans.clear
		tasks.clear
		events.clear
		finalized_tasks.clear
		finalized_events.clear
	    end
	    
	    def prepare_seek(time)
		if !time || !current_time || time < current_time
		    clear
		    event_log.rewind

		    # Re-read the index information
		    index_data.clear
		    index_log.rewind
		    update_index
		end
	    end
	    
	    def read_step
		return if event_log.eof?

		data = Array.new
		FileLogger.replay(event_log) do |method_name, method_args|
		    data << [method_name, method_args]
		    if method_name == :cycle_end
			break
		    end
		end

		data

	    rescue EOFError
	    end
	    
	    def current_time
		return if index_data.empty?
		if index_data.size == current_cycle + 1
		    index_data[current_cycle][:end]
		else
		    index_data[current_cycle][:start]
		end
	    end

	    def next_step_time
		return if index_data.empty?
		if index_data.size > current_cycle + 1
		    index_data[current_cycle + 1][:start]
		end
	    end

	    def advance
		read_step.each do |name, args|
		    reason = catch :ignored do
			begin
			    if respond_to?(name)
				send(name, *args)
			    end
			    displays.each { |d| d.send(name, *args) if d.respond_to?(name) }
			rescue Exception => e
			    display_args = args.map do |obj|
				case obj
				when NilClass: 'nil'
				when Time: obj.to_hms
				when DRbObject: obj.inspect
				else (obj.to_s rescue "failed_to_s")
				end
			    end

			    raise e, "#{e.message} while serving #{name}(#{display_args.join(", ")})", e.backtrace
			end
			nil
		    end
		    if reason
			Roby.warn "Ignored #{name}(#{args.join(", ")}): #{reason}"
		    end
		end
	    ensure
		@current_cycle += 1
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

	    def update_display
		super
		
		# Remove the finalized objects
		finalized_tasks.each do |task, plan|
		    plan.finalized_task(task)
		    Log.remove_object(tasks, task)

		    task.events.each_value do |ev|
			finalized_events[ev] = plan
		    end
		end
		finalized_tasks.clear

		finalized_events.each do |event, plan|
		    plan.finalized_event(event)
		    Log.remove_object(events, event)
		end
		finalized_events.clear
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
		    finalized_tasks.delete(t)
		end
	    end
	    def garbage_task(time, plan, task)
	    end
	    def finalized_event(time, plan, event)
		event = local_event(event)
		plan  = local_plan(plan)
		unless event.respond_to?(:task) || plan.parent_plan && plan.parent_plan.free_events.include?(event)
		    finalized_events[event] = plan
		end
	    end
	    def finalized_task(time, plan, task)
		task = local_task(task)
		throw :ignored, "unknown task" unless task

		plan = local_plan(plan)
		finalized_tasks[task] = plan
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
		Log.remove_object(plans, trsc)
		plan.transactions.delete(trsc)

		# Remove tasks and proxies that have been moved from the
		# transaction to the plan before clearing the transaction
		(trsc.known_tasks - plan.known_tasks).each do |obj|
		    finalized_task(time, trsc, obj)
		end
		(trsc.free_events - plan.free_events).each do |obj|
		    finalized_event(time, trsc, obj)
		end
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
