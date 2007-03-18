module Roby
    module Distributed
	# Set of hooks which send Plan updates to remote hosts
	module PlanModificationHooks
	    def inserted(task)
		super if defined? super
		return unless task.distribute? && task.self_owned?

		unless Distributed.updating?(self) || Distributed.updating?(task)
		    Distributed.each_updated_peer(self, task) do |peer|
			peer.transmit(:plan_set_mission, self, task, true)
		    end
		    Distributed.trigger(task)
		end
	    end

	    def discarded(task)
		super if defined? super
		return unless task.distribute? && task.self_owned?

		unless Distributed.updating?(self) || Distributed.updating?(task)
		    Distributed.each_updated_peer(self, task) do |peer|
			peer.transmit(:plan_set_mission, self, task, false)
		    end
		end
	    end

	    # Common implementation for the #discovered_events and #discovered_tasks hooks
	    def self.discovered_objects(plan, objects)
		unless Distributed.updating?(plan) || Distributed.updating_all?(objects)
		    objects = objects.find_all { |t| t.distribute? && t.self_owned? && t.root_object? }
		    return if objects.empty?

		    Distributed.each_updated_peer(plan) do |peer|
			peer.transmit(:plan_discover, plan, objects)
		    end
		    Distributed.trigger(*objects)
		end
	    end
	    def discovered_tasks(tasks)
		super if defined? super
		PlanModificationHooks.discovered_objects(self, tasks)
	    end
	    def discovered_events(events)
		super if defined? super
		PlanModificationHooks.discovered_objects(self, events) 
	    end

	    def replaced(from, to)
		super if defined? super
		if (from.distribute? && to.distribute?) && (to.self_owned? || from.self_owned?)
		    unless Distributed.updating?(self) || Distributed.updating_all?([from, to])
			Distributed.each_updated_peer(from) do |peer|
			    peer.transmit(:plan_replace, self, from, to)
			end
		    end
		end
	    end

	    # Common implementation for the #finalized_task and #finalized_event hooks
	    def self.finalized_object(plan, object)
		return unless object.distribute? && object.root_object?

		if object.self_owned?
		    Distributed.clean_triggered(object)
		end

		if !Distributed.updating?(plan)
		    Distributed.peers.each_value do |peer|
			if peer.connected? && plan.has_sibling_on?(peer)
			    peer.transmit(:plan_remove_object, plan, object)
			end
		    end
		end

		object.remote_siblings.keys.each do |peer|
		    object.forget_peer(peer) unless peer == Roby::Distributed
		end
	    end
	    def finalized_task(task)
		super if defined? super
		PlanModificationHooks.finalized_object(self, task) 
	    end
	    def finalized_event(event)
		super if defined? super
		PlanModificationHooks.finalized_object(self, event) 
	    end
	end
	Plan.include PlanModificationHooks

	class PeerServer
	    def plan_set_mission(plan, task, flag)
		plan = peer.local_object(plan)

		return unless task = peer.local_object(task)
		task.mission = flag
	    end

	    def plan_discover(plan, m_tasks)
		plan = peer.local_object(plan)

		tasks = ValueSet.new
		m_tasks.each do |marshalled|
		    next unless local = peer.local_object(marshalled)
		    tasks << local
		end
		Distributed.update_all(tasks) { plan.discover(tasks) }
	    end
	    def plan_replace(plan, m_from, m_to)
		plan = peer.local_object(plan)

		# +from+ will be unsubscribed when it is finalized
		from, to = peer.local_object(m_from), peer.local_object(m_to)
		return unless from && to

		Distributed.update_all([from, to]) { plan.replace(from, to) }

		# Subscribe to the new task if the old task was subscribed
		if peer.subscribed?(m_from.remote_object) && !peer.subscribed?(m_to.remote_object)
		    execute do
			peer.subscribe(m_to.remote_object)
		    end
		end
	    end

	    def plan_remove_object(plan, object)
		plan = peer.local_object(plan)

		if local = peer.local_object(object, false)
		    plan.remove_object(local)
		end
	    end

	    # Receive an update on the relation graphs
	    def update_relation(plan, args)
		if plan
		    Roby::Distributed.update(peer.local_object(plan)) { update_relation(nil, args) }
		else
		    m_from, op, m_to, m_rel, m_info = *args
		    from, to = peer.local_object(m_from), 
			peer.local_object(m_to)
		    return if !from || !to

		    rel = peer.local_object(m_rel)
		    if op == :add_child_object
			Roby::Distributed.update_all([from.root_object, to.root_object]) do
			    from.add_child_object(to, rel, peer.local_object(m_info))
			end

		    elsif op == :remove_child_object
			Roby::Distributed.update_all([from.root_object, to.root_object]) do
			    from.remove_child_object(to, rel)
			end
		    end
		end
		nil
	    end
	end

	# This module defines the hooks needed to notify our peers of relation
	# modifications
	module RelationModificationHooks
	    def added_child_object(child, type, info)
		super if defined? super

		return unless type.distribute? && Distributed.state
		return if Distributed.updating_all?([self.root_object, child.root_object])
		Distributed.each_updated_peer(self.root_object, child.root_object) do |peer|
		    peer.transmit(:update_relation, plan, [self, :add_child_object, child, type, info])
		end
		Distributed.trigger(self, child)
	    end

	    def removed_child_object(child, type)
		super if defined? super

		return unless type.distribute? && Distributed.state
		return if Distributed.updating_all?([self.root_object, child.root_object])
		Distributed.each_updated_peer(self.root_object, child.root_object) do |peer|
		    peer.transmit(:update_relation, plan, [self, :remove_child_object, child, type])
		end
		Distributed.trigger(self, child)
	    end
	end
	PlanObject.include RelationModificationHooks

	# This module includes the hooks needed to notify our peers of event
	# propagation (fired, forwarding and signalling)
	module EventNotifications
	    def fired(event)
		super if defined? super
		if self_owned? && !Distributed.updating?(root_object)
		    Distributed.each_updated_peer(root_object) do |peer|
			peer.transmit(:event_fired, self, event.object_id, event.time, nil)
		    end
		end
	    end
	    def forwarding(event, to)
		super if defined? super
		if self_owned? && !Distributed.updating?(root_object)
		    Distributed.each_updated_peer(root_object, to.root_object) do |peer|
			peer.transmit(:event_add_propagation, true, self, to, event.object_id, event.time, nil)
		    end
		end
	    end
	    def signalling(event, to)
		super if defined? super
		if self_owned? && !Distributed.updating?(root_object)
		    Distributed.each_updated_peer(root_object, to.root_object) do |peer|
			peer.transmit(:event_add_propagation, false, self, to, event.object_id, event.time, nil)
		    end
		end
	    end
	end
	Roby::EventGenerator.include EventNotifications

	module PlanCacheCleanup
	    # Removes events generated by +generator+ from the Event object
	    # cache, PeerServer#pending_events. This cache is used by
	    # PeerServer#event_for on behalf of PeerServer#event_fired and
	    # PeerServer#event_add_propagation
	    def finalized_event(generator)
		super if defined? super
		Distributed.peers.each_value do |peer|
		    peer.local.pending_events.delete(generator)
		end
	    end
	end
	Roby::Plan.include PlanCacheCleanup

	class PeerServer
	    attribute(:pending_events) { Hash.new }

	    # Creates an Event object for +generator+, with the given argument
	    # as parameters, or returns an already existing one
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

	    # Called by the peer to notify us about an event which has been fired
	    def event_fired(marshalled_from, event_id, time, context)
		return unless from_generator = peer.local_object(marshalled_from)
		context = peer.local_object(context)
		Distributed.pending_fired << [from_generator, event_for(from_generator, event_id, time, context)]
		nil
	    end

	    # Called by the peer to notify us about an event signalling
	    def event_add_propagation(only_forward, marshalled_from, marshalled_to, event_id, time, context)
		return unless from_generator = peer.local_object(marshalled_from)
		return unless to = peer.local_object(marshalled_to)
		context = peer.local_object(context)
		Distributed.pending_signals << [only_forward, from_generator, to, event_for(from_generator, event_id, time, context)]
		nil
	    end
	end

	@pending_fired   = Array.new
	@pending_signals = Array.new
	class << self
	    def distributed_fire_event(generator, event)
		event.send(:propagation_id=, Propagation.propagation_id)
		generator.fired(event)
	    end

	    # Set of fired events we have been notified about by remote peers
	    attr_reader :pending_fired
	    # Set of signals we have been notified about by remote peers
	    attr_reader :pending_signals
	    # Fire the signals we have been notified about by remote peers
	    def distributed_signals
		seen = ValueSet.new
		while !pending_fired.empty?
		    generator, event = pending_fired.pop
		    seen << event
		    distributed_fire_event(generator, event)
		end

		while !pending_signals.empty?
		    only_forward, from_generator, to_generator, event = pending_signals.pop
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
			Distributed.update_all([from_generator.root_object, to_generator.root_object]) do
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

		unless Distributed.updating?(self)
		    Distributed.each_updated_peer(self) do |peer|
			peer.transmit(:updated_data, self, data)
		    end
		end
	    end
	end
	Roby::Task.include TaskNotifications

	module TaskArgumentsNotifications
	    def updated
		super if defined? super

		unless Distributed.updating?(task)
		    Distributed.each_updated_peer(task) do |peer|
			peer.transmit(:updated_arguments, task, task.arguments)
		    end
		end
	    end
	end
	TaskArguments.include TaskArgumentsNotifications

	class PeerServer
	    def updated_data(task, data)
		proxy = peer.local_object(task)
		Distributed.update(proxy) do
		    proxy.data = data
		end
	    end

	    def updated_arguments(task, arguments)
		proxy = peer.local_object(task)
		Distributed.update(proxy) do
		    proxy.arguments.merge!(arguments || {})
		end
		nil
	    end
	end
    end
end
