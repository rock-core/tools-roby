module Roby
    module Distributed
	# Returns the set of edges for which both sides are in +objects+. The
	# set if formatted as [object, relations, ...] where +relations+ is the
	# output of relations_of
	def self.subgraph_of(objects)
	    return [] if objects.size < 2

	    relations = []

	    objects = objects.dup
	    objects.delete_if do |obj|
		obj_relations = relations_of(obj) do |related_object| 
		    objects.include?(related_object) 
		end
		relations << obj << obj_relations
		true
	    end

	    relations
	end

	# call-seq:
	#   relations_of(object) => relations
	#   relations_of(object) { |object| ... } => relations
	#
	# Relations to be sent to the remote host if +object+ is in a plan. The
	# returned array if formatted as 
	#   [ [graph, parents, children], [graph, ..] ]
	# where +parents+ is the set of parents of +objects+ in +graph+ and
	# +children+ the set of children
	#
	# +parents+ and +children+ are formatted as
	# [object, info, object, info, ...]
	#
	# If a block is given, a new parent or child is added only if the block
	# returns true
	def self.relations_of(object)
	    result = []
	    # For transaction proxies, never send non-discovered relations to
	    # remote hosts
	    Roby::Distributed.each_object_relation(object) do |graph|
		next unless graph.distribute?
		parents = []
		object.each_parent_object(graph) do |parent|
		    next unless parent.distribute?
		    next unless yield(parent) if block_given?
		    parents << parent << parent[object, graph]
		end
		children = []
		object.each_child_object(graph) do |child|
		    next unless child.distribute?
		    next unless yield(child) if block_given?
		    children << child << object[child, graph]
		end
		result << graph << parents << children
	    end

	    result
	end

	# Set of hooks which send Plan updates to remote hosts
	module PlanModificationHooks
            # Hook called when a new task is marked as mission. It sends a
            # PeerServer#plan_set_mission message to the remote host.
            #
            # Note that plan will have called the #added_tasks hook
            # beforehand
	    def added_mission(task)
		super if defined? super
		return unless task.distribute? && task.self_owned?

		unless Distributed.updating?(self) || Distributed.updating?(task)
		    Distributed.each_updated_peer(self, task) do |peer|
			peer.transmit(:plan_set_mission, self, task, true)
		    end
		    Distributed.trigger(task)
		end
	    end

            # Hook called when a new task is not a mission anymore. It sends a
            # PeerServer#plan_set_mission message to the remote host.
	    def unmarked_mission(task)
		super if defined? super
		return unless task.distribute? && task.self_owned?

		unless Distributed.updating?(self) || Distributed.updating?(task)
		    Distributed.each_updated_peer(self, task) do |peer|
			peer.transmit(:plan_set_mission, self, task, false)
		    end
		end
	    end

            # Common implementation for the #added_events and
            # #added_tasks hooks. It sends PeerServer#plan_add for
            # all tasks which can be shared among plan managers
	    def self.added_objects(plan, objects)
		unless Distributed.updating?(plan)
		    relations = nil
		    Distributed.each_updated_peer(plan) do |peer|
			# Compute +objects+ and +relations+ only if there is a
			# peer to update
			unless relations
			    objects = objects.find_all { |t| t.distribute? && t.self_owned? && t.root_object? && !Distributed.updating?(t) }
			    return if objects.empty?
			    relations = Distributed.subgraph_of(objects)
			end
			peer.transmit(:plan_add, plan, objects, relations)
		    end
		    Distributed.trigger(*objects)
		end
	    end
            # New tasks have been added in the plan.
            #
            # See PlanModificationHooks.added_objects
	    def added_tasks(tasks)
		super if defined? super
		PlanModificationHooks.added_objects(self, tasks)
	    end
            # New free events have been added in the plan.
            #
            # See PlanModificationHooks.added_objects
	    def added_events(events)
		super if defined? super
		PlanModificationHooks.added_objects(self, events) 
	    end

            # Hook called when +from+ has been replaced by +to+ in the plan.
            # It sends a PeerServer#plan_replace message
	    def replaced(from, to)
		super if defined? super
		if (from.distribute? && to.distribute?) && (to.self_owned? || from.self_owned?)
		    unless Distributed.updating?(self) || (Distributed.updating?(from) && Distributed.updating?(to))
			Distributed.each_updated_peer(from) do |peer|
			    peer.transmit(:plan_replace, self, from, to)
			end
		    end
		end
	    end

            # Common implementation for the #finalized_task and
            # PeerServer#finalized_event hooks. It sends the plan_remove_object message.
	    def self.finalized_object(plan, object)
		return unless object.distribute? && object.root_object?

		Distributed.keep.delete(object)

		if object.self_owned?
		    Distributed.clean_triggered(object)

		    if !Distributed.updating?(plan)
			Distributed.peers.each_value do |peer|
			    if peer.connected?
				peer.transmit(:plan_remove_object, plan, object)
			    end
			end
		    end

		    if object.remotely_useful?
			Distributed.removed_objects << object
		    end
		else
		    object.remote_siblings.keys.each do |peer|
			object.forget_peer(peer) unless peer == Roby::Distributed
		    end
		end
	    end
            # Hook called when a task has been removed from the plan.
            #
            # See PlanModificationHooks.finalized_object
	    def finalized_task(task)
		super if defined? super
		PlanModificationHooks.finalized_object(self, task) 
	    end
            # Hook called when a free event has been removed from the plan.
            #
            # See PlanModificationHooks.finalized_object
	    def finalized_event(event)
		super if defined? super
		PlanModificationHooks.finalized_object(self, event) 
	    end
	end
	Plan.include PlanModificationHooks

	class PeerServer
            # Message received when +task+ has become a mission (flag = true),
            # or has become a non-mission (flag = false) in +plan+.
	    def plan_set_mission(plan, task, flag)
		plan = peer.local_object(plan)
		task = peer.local_object(task)
		if plan.owns?(task)
		    if flag
			plan.add_mission(task)
		    else
			plan.remove_mission(task)
		    end
		else
		    task.mission = flag
		end
		nil
	    end

            # Message received when the set of tasks +m_tasks+ has been
            # added by the remote plan. +m_relations+ describes the
            # internal relations between elements of +m_tasks+. It is in a
            # format suitable for PeerServer#set_relations.
	    def plan_add(plan, m_tasks, m_relations)
		Distributed.update(plan = peer.local_object(plan)) do
		    tasks = peer.local_object(m_tasks).to_value_set
		    Distributed.update_all(tasks) do 
			plan.add(tasks)
			m_relations.each_slice(2) do |obj, rel|
			    set_relations(obj, rel)
			end
		    end
		end
		nil
	    end

            # Message received when +m_from+ has been replaced by +m_to+ in the
            # plan
	    def plan_replace(plan, m_from, m_to)
		Distributed.update(plan = peer.local_object(plan)) do
		    from, to = peer.local_object(m_from), peer.local_object(m_to)

		    Distributed.update_all([from, to]) { plan.replace(from, to) }

		    # Subscribe to the new task if the old task was subscribed
		    # +from+ will be unsubscribed when it is finalized
		    if peer.subscribed?(from) && !peer.subscribed?(to)
			peer.subscribe(to)
			nil
		    end
		end
		nil
	    end

            # Message received when +object+ has been removed from +plan+
	    def plan_remove_object(plan, object)
		if local = peer.local_object(object, false)
		    # Beware, transaction proxies have no 'plan' attribute
		    plan = peer.local_object(plan)
		    Distributed.update(plan) do
			Distributed.update(local) do
			    plan.remove_object(local)
			end
		    end
		    local.forget_peer(peer)
		end

	    rescue ArgumentError => e
		if e.message =~ /has not been included in this plan/
		    Roby::Distributed.warn "filtering the 'not included in this plan bug'"
		else
		    raise
		end
	    end

            # Message received when a relation graph has been updated. +op+ is
            # either +add_child_object+ or +remove_child_object+ and describes
            # what relation modification should be done. The two plan objects
            # +m_from+ and +m_to+ are respectively linked or unlinked in the
            # relation +m_rel+, with the given information object in case of a
            # new relation.
	    def update_relation(plan, m_from, op, m_to, m_rel, m_info = nil)
		if plan
		    Roby::Distributed.update(peer.local_object(plan)) { update_relation(nil, m_from, op, m_to, m_rel, m_info) }
		else
		    from, to = 
			peer.local_object(m_from, false), 
			peer.local_object(m_to, false)

		    if !from
			return unless to && (to.self_owned? || to.subscribed?)
			from = peer.local_object(m_from)
		    elsif !to
			return unless from && (from.self_owned? || from.subscribed?)
			to   = peer.local_object(m_to)
		    end

		    rel = peer.local_object(m_rel)
		    Roby::Distributed.update_all([from.root_object, to.root_object]) do
			if op == :add_child_object
			    from.add_child_object(to, rel, peer.local_object(m_info))
			elsif op == :remove_child_object
			    from.remove_child_object(to, rel)
			end
		    end
		end
		nil
	    end
	end

        # This module defines the hooks needed to notify our peers of relation
        # modifications. It is included in plan objects.
	module RelationModificationHooks
            # Hook called when a new relation is added. It sends the
            # PeerServer#update_relation message.
	    def added_child_object(child, relations, info)
		super if defined? super

		return if !Distributed.state
		return if Distributed.updating?(plan)
		return if Distributed.updating?(self.root_object) && Distributed.updating?(child.root_object)

		# Remove all relations that should not be distributed, and if
		# there is a relation remaining, notify our peer only of the
		# first one: this is the child of all others
		if notified_relation = relations.find { |rel| rel.distribute? }
		    Distributed.each_updated_peer(self.root_object, child.root_object) do |peer|
			peer.transmit(:update_relation, plan, self, :add_child_object, child, notified_relation, info)
		    end
		    Distributed.trigger(self, child)
		end
	    end

            # Hook called when a relation is removed. It sends the
            # PeerServer#update_relation message.
	    def removed_child_object(child, relations)
		super if defined? super
		return if !Distributed.state

		# If our peer is pushing a distributed transaction, children
		# can be removed Avoid sending unneeded updates by testing on
		# plan update
		return if Distributed.updating?(plan)
		return if Distributed.updating?(self.root_object) && Distributed.updating?(child.root_object)

		# Remove all relations that should not be distributed, and if
		# there is a relation remaining, notify our peer only of the
		# first one: this is the child of all others
		if notified_relation = relations.find { |rel| rel.distribute? }
		    Distributed.each_updated_peer(self.root_object, child.root_object) do |peer|
			peer.transmit(:update_relation, plan, self, :remove_child_object, child, notified_relation)
		    end
		    Distributed.trigger(self, child)
		end
	    end
	end
	PlanObject.include RelationModificationHooks

        # This module includes the hooks needed to notify our peers of event
        # propagation (fired, forwarding and signalling)
	module EventNotifications
            # Hook called when an event has been emitted. It sends the
            # PeerServer#event_fired message.
	    def fired(event)
		super if defined? super
		if self_owned? && !Distributed.updating?(root_object)
		    Distributed.each_updated_peer(root_object) do |peer|
			peer.transmit(:event_fired, self, event.object_id, event.time, event.context)
		    end
		end
	    end
            # Hook called when an event is being forwarded. It sends the
            # PeerServer#event_add_propagation message.
	    def forwarding(event, to)
		super if defined? super
		if self_owned? && !Distributed.updating?(root_object)
		    Distributed.each_updated_peer(root_object, to.root_object) do |peer|
			peer.transmit(:event_add_propagation, true, self, to, event.object_id, event.time, event.context)
		    end
		end
	    end
            # Hook called when an event is being forwarded. It sends the
            # PeerServer#event_add_propagation message.
	    def signalling(event, to)
		super if defined? super
		if self_owned? && !Distributed.updating?(root_object)
		    Distributed.each_updated_peer(root_object, to.root_object) do |peer|
			peer.transmit(:event_add_propagation, false, self, to, event.object_id, event.time, event.context)
		    end
		end
	    end

            # This module define hooks on Roby::Plan to manage the event fired
            # cache. It is required by the receiving side of the event
            # propagation distribution.
            #
            # See PeerServer#pending_events
            module PlanCacheCleanup
                # Removes events generated by +generator+ from the Event object
                # cache, PeerServer#pending_events. This cache is used by
                # PeerServer#event_for on behalf of PeerServer#event_fired and
                # PeerServer#event_add_propagation
                def finalized_event(generator)
                    super if defined? super
                    Distributed.peers.each_value do |peer|
                        if peer.local_server
                            peer.local_server.pending_events.delete(generator)
                        end
                    end
                end
            end
            Roby::Plan.include PlanCacheCleanup
	end
	Roby::EventGenerator.include EventNotifications

	class PeerServer
            # A set of events which have been received by #event_fired. This
            # cache in cleaned up by PlanCacheCleanup#finalized_event when the
            # associated generator is finalized.
            #
            # This cache is used to merge the events between the firing step
            # (event_fired) and the propagation steps (add_event_propagation).
            # Without it, different Event objects at the various method calls.
	    attribute(:pending_events) { Hash.new }

	    # Creates an Event object for +generator+, with the given argument
	    # as parameters, or returns an already existing one
	    def event_for(generator, event_id, time, context)
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

            # Message received when the +marshalled_from+ generator fired an
            # event, with the given event id, time and context.
	    def event_fired(marshalled_from, event_id, time, context)
		from_generator = peer.local_object(marshalled_from)
		context	       = peer.local_object(context)

		event = event_for(from_generator, event_id, time, context)

		event.send(:propagation_id=, from_generator.plan.engine.propagation_id)
		from_generator.instance_variable_set("@happened", true)
		from_generator.fired(event)
		from_generator.call_handlers(event)

		nil
	    end

            # Message received when the +marshalled_from+ generator has either
            # been forwarded (only_forward = true) or signals (only_forward =
            # false) the +marshalled_to+ generator. The remaining information
            # describes the event itself.
	    def event_add_propagation(only_forward, marshalled_from, marshalled_to, event_id, time, context)
		from_generator  = peer.local_object(marshalled_from)
		to_generator	= peer.local_object(marshalled_to)
		context         = peer.local_object(context)

		event		= event_for(from_generator, event_id, time, context)

		# Only add the signalling if we own +to+
		if to_generator.self_owned?
                    to_generator.plan.engine.add_event_propagation(only_forward, [event], to_generator, event.context, nil)
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

		nil
	    end
	end

        # This module defines the hooks required by dRoby on Roby::Task
	module TaskNotifications
            # Hook called when the internal task data is modified. It sends
            # PeerServer#updated_data
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

        # This module defines the hooks required by dRoby on Roby::TaskArguments
	module TaskArgumentsNotifications
            # Hook called when the task argumensts are modified. It sends
            # the PeerServer#updated_arguments message.
	    def updated(key, value)
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
            # Message received to announce that the internal data of +task+ is
            # now +data+.
	    def updated_data(task, data)
		proxy = peer.local_object(task)
		proxy.instance_variable_set("@data", peer.proxy(data))
		nil
	    end

            # Message received to announce that the arguments of +task+ have
            # been modified. +arguments+ is a hash containing only the new
            # values.
	    def updated_arguments(task, arguments)
		proxy = peer.local_object(task)
		arguments = peer.proxy(arguments)
		Distributed.update(proxy) do
		    proxy.arguments.merge!(arguments || {})
		end
		nil
	    end
	end

	class PeerServer
            # Message received to update our view of the remote robot state.
	    def state_update(new_state)
		peer.state = new_state
		nil
	    end
	end
    end
end
