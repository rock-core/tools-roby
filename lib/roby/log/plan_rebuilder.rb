require 'roby/distributed'
require 'roby/log/data_stream'
require 'stringio'

module Roby
    module LogReplay
        module ReplayPlan
            attribute(:finalized_tasks)  { ValueSet.new }
            attribute(:finalized_events) { ValueSet.new }

            def clear
                super if defined? super
                transactions.dup.each do |trsc|
                    trsc.discard
                end
                clear_finalized(finalized_tasks, finalized_events)
            end

            def finalized_task(task)
                finalized_tasks << task
            end
            def finalized_event(event)
                if event.root_object?
                    finalized_events << event
                end
            end
            def clear_finalized(tasks, events)
                tasks.each { |task| task.clear_vertex }
                @finalized_tasks = finalized_tasks - tasks
                events.each { |event| event.clear_vertex }
                @finalized_events = finalized_events - events
            end
        end

        module PlanReplayTaskModel
            def create_remote_event(symbol, peer, marshalled_event)
                event_model = self.model.
                    event(symbol, :controlable => marshalled_event.controlable)
                @bound_events[symbol] = Roby::TaskEventGenerator.new(self, event_model)
            end
        end

        class PlanReplayPeer < Roby::Distributed::RemoteObjectManager
            def connected?
                false
            end

            def transmit(*args)
            end

            def local_model(parent_model, name, &block)
                new_model = super
                if new_model <= Roby::Task && !new_model.has_ancestor?(PlanReplayTaskModel)
                    new_model.include(PlanReplayTaskModel)
                end
                new_model
            end

            def remote_name
                "log_replay"
            end
            def name; remote_name end
        end

	# This class rebuilds a plan-like structure from events saved by a
	# FileLogger object This is compatible with the EventStream data source
	class PlanRebuilder < DataDecoder
	    attr_reader :last_finalized
	    attr_reader :manager

            attr_reader :plan
            attr_reader :plans

	    attr_reader :start_time
	    attr_reader :time
	    def initialize(name)
                @plan = Roby::Plan.new
                @plan.extend ReplayPlan
                @plans = [@plan].to_value_set

		@last_finalized = Hash.new
		super(name)
	    end

            def create_remote_object_manager
		manager = PlanReplayPeer.new(plan)
                manager.use_local_sibling = false
                manager.proxies[Distributed.remote_id] = manager
                Distributed.setup_log_replay(manager)
                plan.owners << manager
                manager
            end
	    
	    def clear
                @manager = create_remote_object_manager
		super

		plans.dup.each { |p, _| p.clear if p.root_plan? }
		@start_time = nil
		@time = nil
	    end

	    def rewind
		clear
	    end
	    
            # Processes one cycle worth of data coming from an EventStream, and
            # builds the corresponding plan representation
            #
            # It returns true if there was something noteworthy in there, and
            # false otherwise.
	    def process(data)
		@time = data.last[0][:start]
	        @start_time ||= @time

                done_something = false
		data.each_slice(4) do |m, sec, usec, args|
		    time = Time.at(sec, usec)
		    reason = catch :ignored do
			begin
			    if respond_to?(m)
				send(m, time, *args)
                                done_someting = true
			    end
			    displays.each do |d|
                                if d.respond_to?(m)
                                    done_something = true
                                    d.send(m, time, *args) 
                                end
                            end
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
                done_something
	    end

	    def local_object(object, create = true)
		return nil unless object
		manager.local_object(object, create)
	    end

	    def clear_integrated
                updated = false
		plans.each do |plan|
                    updated = !(plan.finalized_events.empty? && plan.finalized_tasks.empty?)
		    plan.clear_finalized(plan.finalized_tasks.dup, plan.finalized_events.dup)
		end

		super_result = super
                super_result || updated
	    end

	    def inserted_tasks(time, plan, task)
		plan = local_object(plan)
		plan.add_mission( local_object(task) )
	    end
	    def discarded_tasks(time, plan, task)
		plan = local_object(plan)
		plan.remove_mission(local_object(task))
	    end
	    def replaced_tasks(time, plan, from, to)
	    end
	    def added_events(time, plan, events)
		plan = local_object(plan)
		events.each do |ev| 
		    ev = local_object(ev) { plan }
                    if ev.kind_of?(Roby::Distributed::RemoteID)
                        raise "cannot find tracked object for #{ev}"
                    end
                    # Update the plan in case +ev+ was an event in a transaction
                    # that got committed
                    ev.plan = plan
		    plan.free_events << ev
		end
	    end
	    def added_tasks(time, plan, tasks)
		plan = local_object(plan)
		tasks.each do |t| 
                    t = local_object(t)
		    plan.add(local_object(t))
		end
	    end
	    def garbage_task(time, plan, task)
	    end
	    def finalized_event(time, plan, event)
		event = local_object(event)
		plan  = local_object(plan)
		if event.root_object?
		    plan.remove_object(event)
		end
	    end
	    def finalized_task(time, plan, task)
		task = local_object(task)
		plan = local_object(plan)
		plan.remove_object(task)
	    end
	    def added_transaction(time, plan, trsc)
		plan = local_object(plan)
		trsc = local_object(trsc, true)
                plans << trsc
	    end
	    def removed_transaction(time, plan, trsc)
		plan = local_object(plan)
		trsc = local_object(trsc)
		trsc.clear_finalized(trsc.finalized_tasks, trsc.finalized_events)
		plans.delete(trsc)
	    end

	    GENERATOR_TO_STATE = { :start => :started,
		:success => :success,
		:stop => :finished }

	    def generator_fired(time, generator, id, ev_time, context)
		generator = local_object(generator)
                event = generator.new(context, id, ev_time)
                if generator.respond_to?(:task)
                    generator.task.update_task_status(event)
                end
	    end

	    def added_task_child(time, parent, rel, child, info)
		parent = local_object(parent)
		child  = local_object(child)
		if !parent   then throw :ignored, "unknown parent"
		elsif !child then throw :ignored, "unknown child"
		end

		rel = rel.first if rel.kind_of?(Array)
		rel    = rel.proxy(nil)
		parent.add_child_object(child, rel, info)
                return parent, rel, child
	    end
	    def removed_task_child(time, parent, rel, child)
		parent = local_object(parent)
		child  = local_object(child)
		rel = rel.first if rel.kind_of?(Array)
		rel    = rel.proxy(nil)
		parent.remove_child_object(child, rel)
                return parent, rel, child
	    end
	    def added_event_child(time, parent, rel, child, info)
		parent = local_object(parent)
		child  = local_object(child)
                rel    = local_object(rel)
		parent.add_child_object(child, rel.first, info)
	    end
	    def removed_event_child(time, parent, rel, child)
		parent = local_object(parent)
		child  = local_object(child)
                rel    = local_object(rel)
		parent.remove_child_object(child, rel.first)
	    end
	    def added_owner(time, object, peer)
		object = local_object(object)
		object.owners << peer
	    end
	    def removed_owner(time, object, peer)
		object = local_object(object)
		object.owners.delete(peer)
	    end
	end

	module TaskDisplaySupport
	    # A regex => boolean map of prefixes that should be removed from
	    # the task names
	    attribute :removed_prefixes do
		{ "Roby::" => false, 
		    "Roby::Genom::" => false }
	    end

	    # Compute the prefixes to remove from in filter_prefixes:
	    # enable only the ones that are flagged, and sort them by
	    # prefix length
	    def update_prefixes_removal
		@prefixes_removal = removed_prefixes.find_all { |p, b| b }.
		    map { |p, b| p }.
		    sort_by { |p| p.length }.
		    reverse
	    end

	    def filter_prefixes(string)
		# @prefixes_removal is computed in RelationsCanvas#update
		for prefix in @prefixes_removal
		    string = string.gsub(prefix, '')
		end
		string
	    end

	    # If true, show the ownership in the task descriptions
	    attribute(:show_ownership) { true }
	    # If true, show the arguments in the task descriptions
	    attribute(:show_arguments) { false }
	end

    end
end

