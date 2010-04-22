require 'roby/distributed/protocol'
require 'roby/log/data_stream'
require 'stringio'

module Roby
    module LogReplay
        class ObjectIDManager
            attr_reader :siblings
            attr_reader :objects
            def initialize
                @siblings = Hash.new
                @objects  = Hash.new
                @inserted_at = Hash.new
            end

            def clear
                siblings.clear
                objects.clear
            end

            def local_object(object, allow_new = true)
                return unless object

                current_siblings = Set.new
                ids = Set.new
                if object.kind_of?(Distributed::RemoteID) 
                    ids << object
                    if sibling = siblings[object]
                        current_siblings << sibling
                    end
                else
                    for _, id in object.remote_siblings
                        ids << id
                        if sibling = siblings[id]
                            current_siblings << sibling
                        end
                    end
                end

                if current_siblings.size > 1
                    raise "more than one object matching"
                elsif current_siblings.empty?
                    if object.kind_of?(Distributed::RemoteID)
                        raise "no object for this ID"
                    elsif !allow_new
                        raise "new object ot type #{object.class} is not allowed here"
                    end
                else
                    obj = current_siblings.find { true }
                    if object.kind_of?(Distributed::RemoteID)
                        object = obj
                    end

                    if obj.class != object.class
                        # Special case: +obj+ is a PlanObject and it is in no plan.
                        #
                        # In this case, we just replace it silently. It handles the
                        # corner case of having a task hanging around because it is
                        # linked to others, but has not been included in a plan.
                        #
                        # Note that this is a hack and should be fixed
                        if obj.respond_to?(:plan) && !obj.plan
                            for id in objects.delete(obj)
                                siblings.delete(id)
                            end
                        else
                            raise "class mismatch #{obj.class} != #{object.class}. Old object is #{obj}"
                        end
                    elsif block_given?
                        ids.merge objects.delete(obj)
                        object = yield(obj)
                    else
                        object = obj
                    end
                end

                objects[object] ||= Set.new
                objects[object].merge ids
                for i in ids
                    siblings[i] = object
                end

                object
            end

            def add_id(object, id)
                if siblings[id]
                    raise "there is already an object for this ID"
                elsif !id.kind_of(Distributed::RemoteID)
                    raise "#{id} is not a valid RemoteID"
                end

                siblings[id] = object
                objects[object] << id
            end

            def remove_id(id)
                if !(object = siblings.delete(id))
                    raise "#{id} does not reference anything"
                end
                objects[object].delete(id)
            end

            def remove(object)
                object = local_object(object)

                ids = objects.delete(object)
                for i in ids
                    siblings.delete(i)
                end
            end
        end

        module ReplayPlanObject
            include DirectedRelationSupport
            attr_writer :plan
            def update_from(new)
                super if defined? super
            end
        end

        module ReplayTaskEventGenerator
            include ReplayPlanObject
            attr_writer :task
        end

        module ReplayTask
            include ReplayPlanObject
            attribute(:events) { Hash.new }

            def update_from(new)
                super if defined? super
                self.flags.merge! new.flags
                self.plan  = new.plan
            end
        end

        module ReplayTaskProxy
            include ReplayPlanObject
            attr_writer :transaction

            def events; Hash.new end
            def update_from(new)
                super if defined? super
            end
        end

        module ReplayPlan
            attribute(:missions)	 { ValueSet.new }
            attribute(:known_tasks)  { ValueSet.new }
            attribute(:free_events)  { ValueSet.new }
            attribute(:transactions) { ValueSet.new }
            attribute(:finalized_tasks)  { ValueSet.new }
            attribute(:finalized_events) { ValueSet.new }
            attribute(:proxies) { ValueSet.new }
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
                clear_finalized(finalized_tasks, finalized_events)
            end

            def finalized_task(task)
                missions.delete(task)
                known_tasks.delete(task)
                proxies.delete(task)
                finalized_tasks << task
            end
            def finalized_event(event)
                free_events.delete(event)
                proxies.delete(event)
                finalized_events << event unless event.respond_to?(:task)
            end
            def clear_finalized(tasks, events)
                tasks.each { |task| task.clear_vertex }
                @finalized_tasks = finalized_tasks - tasks
                events.each { |event| event.clear_vertex }
                @finalized_events = finalized_events - events
            end
            def removed_transaction(trsc)
                transactions.delete(trsc)
            end
        end

        Roby::PlanObject::DRoby.include ReplayPlanObject
        Roby::TaskEventGenerator::DRoby.include ReplayTaskEventGenerator
        Roby::Task::DRoby.include ReplayTask
        Roby::Task::Proxying::DRoby.include ReplayTaskProxy
        Roby::Plan::DRoby.include ReplayPlan
        Roby::Distributed::Transaction::DRoby.include ReplayPlan

	# This class rebuilds a plan-like structure from events saved by a
	# FileLogger object This is compatible with the EventStream data source
	class PlanRebuilder < DataDecoder
	    attr_reader :plans
	    attr_reader :tasks
	    attr_reader :events
	    attr_reader :last_finalized
	    attr_reader :manager

	    attr_reader :start_time
	    attr_reader :time
	    def initialize(name)
		@plans  = ValueSet.new
		@tasks  = ValueSet.new
		@events = ValueSet.new
		@manager = ObjectIDManager.new
		@last_finalized = Hash.new
		super(name)
	    end
	    
	    def clear
		manager.clear
		super

		plans.dup.each { |p, _| p.clear if p.root_plan? }
		plans.clear
		tasks.clear
		events.clear
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

	    def local_object(object)
		return nil unless object

		object = manager.local_object(object)
		plan = if block_given?
			   yield
		       elsif object.respond_to?(:transaction)
			   local_plan(object.transaction, false)
		       elsif object.respond_to?(:plan)
			   local_plan(object.plan, false)
		       end

		if plan
		    object.plan = plan
		    if object.respond_to?(:transaction)
			object.transaction = plan
			plan.proxies << object
		    end
		end

		object
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

	    def local_plan(plan, allow_new = false)
	       	plan = manager.local_object(plan, plans.empty? || allow_new)
		plans << plan if plan
		plan
	    end
	    def local_task(task, &block)
		local_object(task, &block)
	    end
	    def local_event(event, &block)
		if event.respond_to?(:task)
		    task = local_task(event.task, &block)
		    if task.events[event.symbol]
			task.events[event.symbol]
		    else
			event.task = task
			event.plan = task.plan
			task.events[event.symbol] = event 
		    end
		else
		    local_object(event, &block) 
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
	    def added_events(time, plan, events)
		plan = local_plan(plan)
		events.each do |ev| 
		    ev = local_event(ev) { plan }
		    plan.free_events << ev
		end
	    end
	    def added_tasks(time, plan, tasks)
		plan = local_plan(plan)
		tasks.each do |t| 
		    t = local_task(t) { plan }
		    plan.known_tasks << t
		end
	    end
	    def garbage_task(time, plan, task)
	    end
	    def finalized_event(time, plan, event)
		event = local_event(event)
		plan  = local_plan(plan)
		unless event.respond_to?(:task)
		    plan.finalized_event(event)
		    manager.remove(event)
		end
	    end
	    def finalized_task(time, plan, task)
		task = local_task(task)
		plan = local_plan(plan)
		plan.finalized_task(task)
		manager.remove(task)
	    end
	    def added_transaction(time, plan, trsc)
		plan = local_plan(plan)
		trsc = local_plan(trsc, true)
		plan.transactions << trsc
		trsc.parent_plan  = plan
	    end
	    def removed_transaction(time, plan, trsc)
		plan = local_plan(plan)
		trsc = local_plan(trsc)
		    
		(trsc.known_tasks - plan.known_tasks).each do |obj|
		    trsc.finalized_task(obj)
		    manager.remove(obj)
		end
		(trsc.free_events - plan.free_events).each do |obj|
		    trsc.finalized_event(obj)
		    manager.remove(obj)
		end
		trsc.proxies.each do |p|
		    manager.remove(p)
		end

		trsc.clear_finalized(trsc.finalized_tasks, trsc.finalized_events)
		plans.delete(trsc)
		manager.remove(trsc)
		plan.transactions.delete(trsc)
	    end

	    GENERATOR_TO_STATE = { :start => :started,
		:success => :success,
		:stop => :finished }

	    def generator_fired(time, generator, id, ev_time, context)
		generator = local_event(generator)
		generator.instance_variable_set("@happened", true)
		if generator.respond_to?(:task) && (state = GENERATOR_TO_STATE[generator.symbol])
		    generator.task.flags[state] = true
		end
	    end

	    def added_task_child(time, parent, rel, child, info)
		parent = local_task(parent)
		child  = local_task(child)
		if !parent   then throw :ignored, "unknown parent"
		elsif !child then throw :ignored, "unknown child"
		end

		rel = rel.first if rel.kind_of?(Array)
		rel    = rel.proxy(nil)
		parent.add_child_object(child, rel, info)
	    end
	    def removed_task_child(time, parent, rel, child)
		parent = local_task(parent)
		child  = local_task(child)
		rel = rel.first if rel.kind_of?(Array)
		rel    = rel.proxy(nil)
		parent.remove_child_object(child, rel)
	    end
	    def added_event_child(time, parent, rel, child, info)
		parent = local_event(parent)
		child  = local_event(child)
		rel = rel.first if rel.kind_of?(Array)
		rel    = rel.proxy(nil)
		parent.add_child_object(child, rel, info)
	    end
	    def removed_event_child(time, parent, rel, child)
		parent = local_event(parent)
		child  = local_event(child)
		rel = rel.first if rel.kind_of?(Array)
		rel    = rel.proxy(nil)
		parent.remove_child_object(child, rel)
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

