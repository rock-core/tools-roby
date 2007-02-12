module Roby
    module Distributed
	# Set of hooks to send Plan updates to remote hosts
	module PlanModificationHooks
	    def inserted(task)
		super if defined? super
		return unless task.distribute? && task.self_owned?

		unless Distributed.updating?([self]) || Distributed.updating?([task])
		    Distributed.trigger(task)
		    Distributed.each_subscribed_peer(self) do |peer|
			peer.plan_update(:insert, self, task)
		    end
		end
	    end
	    def discovered_tasks(tasks)
		super if defined? super
		unless Distributed.updating?([self]) || Distributed.updating?(tasks)
		    tasks = tasks.find_all { |t| t.distribute? && t.self_owned? }
		    return if tasks.empty?

		    Distributed.trigger(*tasks)
		    Distributed.each_subscribed_peer(self) do |peer|
			peer.plan_update(:discover, self, tasks)
		    end
		end
	    end
	    alias :discovered_events :discovered_tasks

	    def discarded(task)
		super if defined? super
		return unless task.distribute? && task.self_owned?

		unless Distributed.updating?([self]) || Distributed.updating?([task])
		    Distributed.each_subscribed_peer(self) do |peer|
			peer.plan_update(:discard, self, task)
		    end
		end
	    end
	    def replaced(from, to)
		super if defined? super
		if (from.distribute? && to.distribute?) && (to.self_owned? || from.self_owned?)
		    unless Distributed.updating?([self]) || Distributed.updating?([from, to])
			Distributed.each_subscribed_peer(from) do |peer|
			    peer.plan_update(:replace, self, from, to)
			end
		    end
		end
	    end
	    def finalized_task(task)
		super if defined? super
		return unless task.distribute? && task.self_owned?

		unless Distributed.updating?([self])
		    Distributed.clean_triggered(task)
		    #Distributed.each_subscribed_peer(task) do |peer|
		    Distributed.peers.each do |_, peer|
			if peer.connected?
			    peer.plan_update(:remove_object, self, task)
			end
		    end
		end
	    end
	    def finalized_event(event)
		super if defined? super
		return unless event.distribute? && event.self_owned?
		return unless event.root_object?

		unless Distributed.updating?([self])
		    #Distributed.each_subscribed_peer(event) do |peer|
		    Distributed.peers.each do |_, peer|
			if peer.connected?
			    peer.plan_update(:remove_object, self, event)
			end
		    end
		end
	    end
	    def added_transaction(trsc)
		super if defined? super
		unless Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self) do |peer|
			peer.transaction_update(:added_transaction, self, trsc)
		    end
		end
	    end
	    def removed_transaction(trsc)
		super if defined? super
		unless Distributed.updating?([self])
		    Distributed.each_subscribed_peer(trsc) do |peer|
			peer.transaction_update(:removed_transaction, self, trsc)
		    end
		end
	    end
	end
	Plan.include PlanModificationHooks

	class PeerServer
	    # Notification of a plan modification. +event+ is the name of the
	    # plan method which needs to be called, +marshalled_plan+ the plan
	    # itself and +args+ the args to +event+
	    def plan_update(event, marshalled_plan, args)
		plan = peer.local_object(marshalled_plan)

		result = []
		Distributed.update([plan]) do
		    case event.to_sym
		    when :discover
			result = ValueSet.new
			args[0].each do |marshalled|
			    next unless local = peer.local_object(marshalled)
			    result << local
			    peer.subscriptions << marshalled.remote_object
			end
			Distributed.update(result) do
			    plan.discover(result)
			end

		    when :replace 
			# +from+ will be unsubscribed when it is finalized
			marshalled_from, marshalled_to = *args
			from, to = peer.local_object(marshalled_from), peer.local_object(marshalled_to)
			return unless from && to
			if peer.owns?(marshalled_to.remote_object) && !peer.subscribed?(marshalled_to.remote_object)
			    peer.subscriptions << marshalled_to.remote_object
			end
			Distributed.update([from, to]) do
			    plan.replace(from, to)
			end

		    when :remove_object
			marshalled = args[0]
			local = peer.local_object(marshalled, false)
			return unless local
			if local.plan
			    plan.remove_object(local)
			end
			peer.delete(marshalled.remote_object)
		    end
		end
		nil
	    end

	    def transaction_update(marshalled_plan, event, marshalled_trsc)
		plan = peer.local_object(marshalled_plan)
		if event == :removed_transaction
		    trsc = peer.local_object(marshalled_trsc)
		end
		nil
	    end
	end
	class Peer
	    def plan_update(event, plan, *args)
		case event
		when :discover
		    args[0].find_all { |obj| obj.self_owned? }.
			each do |obj| 
			    local.subscribe(obj)
			end

		when :remove_object
		    local.subscriptions.delete(args[0]) if args[0].self_owned?
		end

	       	transmit(:plan_update, event, plan, args)
	    end
	    def transaction_update(*args); transmit(:transaction_update, *args) end
	end

	# Set of hooks to propagate relation modifications for subscribed tasks
	module RelationModificationHooks
	    def added_child_object(child, type, info)
		super if defined? super

		return unless type.distribute? && Distributed.state
		return if Distributed.updating?([self.root_object, child.root_object])
		Distributed.trigger(self, child)
		Distributed.each_subscribed_peer(self.root_object, child.root_object) do |peer|
		    peer.transmit(:update_relation, plan, [self, :add_child_object, child, type, info])
		end
	    end

	    def removed_child_object(child, type)
		super if defined? super

		return unless type.distribute? && Distributed.state
		return if Distributed.updating?([self.root_object, child.root_object])
		Distributed.trigger(self, child)
		Distributed.each_subscribed_peer(self.root_object, child.root_object) do |peer|
		    peer.transmit(:update_relation, plan, [self, :remove_child_object, child, type])
		end
	    end
	end
	PlanObject.include RelationModificationHooks

	module EventNotifications
	    def fired(event)
		super if defined? super
		if self_owned? && !Distributed.updating?([root_object])
		    Distributed.each_subscribed_peer(root_object) do |peer|
			peer.transmit(:event_fired, self, event.object_id, event.time, nil)
		    end
		end
	    end
	    def forwarding(event, to)
		super if defined? super
		if self_owned? && !Distributed.updating?([root_object])
		    Distributed.each_subscribed_peer(root_object, to.root_object) do |peer|
			peer.transmit(:event_add_propagation, true, self, to, event.object_id, event.time, nil)
		    end
		end
	    end
	    def signalling(event, to)
		super if defined? super
		if self_owned? && !Distributed.updating?([root_object])
		    Distributed.each_subscribed_peer(root_object, to.root_object) do |peer|
			peer.transmit(:event_add_propagation, false, self, to, event.object_id, event.time, nil)
		    end
		end
	    end
	end
	Roby::EventGenerator.include EventNotifications

	module PlanCacheCleanup
	    def finalized_event(generator)
		super if defined? super
		Distributed.peers.each do |_, peer|
		    peer.local.pending_events.delete(generator)
		end
	    end
	end
	Roby::Plan.include PlanCacheCleanup

	class PeerServer
	    attribute(:pending_events) { Hash.new }
	    def event_for(generator, event_id, time, context)
		# This must be done at reception time, or we will invert
		# operations (for instance, we could do a remove_object on a
		# task which is not finished yet)

		id, event = pending_events[generator]
		if id && id == event_id
		    return event
		end
		
		event = generator.new(context)
		event.send(:time=, time)
		if generator.respond_to?(:task)
		    generator.task.update_task_status(event)
		end
		pending_events[generator] = [event_id, event]
		event
	    end

	    def event_fired(marshalled_from, event_id, time, context)
		return unless from_generator = peer.local_object(marshalled_from)
		return unless from_generator.plan
		context        = peer.local_object(context)
		Distributed.pending_fired << [from_generator, event_for(from_generator, event_id, time, context)]
		nil
	    end

	    def event_add_propagation(only_forward, marshalled_from, marshalled_to, event_id, time, context)
		return unless from_generator = peer.local_object(marshalled_from)
		return unless from_generator.plan
		return unless to             = peer.local_object(marshalled_to)
		return unless to.plan
		context        = peer.local_object(context)
		Distributed.pending_signals << [only_forward, from_generator, to, event_for(from_generator, event_id, time, context)]
		nil
	    end
	end

	@pending_fired   = Queue.new
	@pending_signals = Queue.new
	class << self
	    def distributed_fire_event(generator, event)
		event.send(:propagation_id=, Propagation.propagation_id)
		generator.fired(event)
	    end

	    attr_reader :pending_fired, :pending_signals
	    def distributed_signals
		seen = ValueSet.new
		pending_fired.get(true).each do |generator, event|
		    seen << event
		    distributed_fire_event(generator, event)
		end

		pending_signals.get(true).each do |only_forward, from_generator, to_generator, event|
		    unless seen.include?(event)
			distributed_fire_event(from_generator, event)
		    end

		    # Only add the signalling if we own +to+
		    if to_generator.self_owned?
			Propagation.add_event_propagation(only_forward, [event], to_generator, event.context, nil)
		    else
			# Call #signalling or #forwarding to make
			# +from_generator+ look like as if the event was really
			# fired locally ...
			Distributed.update([from_generator.root_object, to_generator.root_object]) do
			    if only_forward then from_generator.forwarding(event, to_generator)
			    else from_generator.signalling(event, to_generator)
			    end
			end
		    end
		end
	    end
	end
	Control.event_processing << Distributed.method(:distributed_signals)

	module TaskNotifications
	    def updated_data
		super if defined? super

		unless Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self) do |peer|
			peer.transmit(:updated_data, self, data)
		    end
		end
	    end
	end
	Roby::Task.include TaskNotifications

	module TaskArgumentsNotifications
	    def updated
		super if defined? super

		unless Distributed.updating?([task])
		    Distributed.each_subscribed_peer(task) do |peer|
			peer.transmit(:updated_arguments, task, task.arguments)
		    end
		end
	    end
	end
	TaskArguments.include TaskArgumentsNotifications

	class PeerServer
	    def updated_data(task, data)
		proxy = peer.local_object(task)
		Distributed.update([proxy]) do
		    proxy.data = data
		end
	    end

	    def updated_arguments(task, arguments)
		proxy = peer.local_object(task)
		Distributed.update([proxy]) do
		    proxy.arguments.merge!(arguments || {})
		end
		nil
	    end
	end
    end
end
