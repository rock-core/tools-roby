
module Roby
    module Distributed
	class << self
	    def each_updated_peer(*objects)
		return if objects.any? { |o| !o.distribute? }
		Distributed.peers.each_value do |peer|
		    next unless peer.connected?
		    return unless objects.any? { |obj| obj.update_on?(peer) }
		    yield(peer)
		end
	    end
	end

	class PeerServer
	    # Called by the peer to subscribe on +object+. Returns an array which
	    # is to be fed to #demux to update the object relations on the remote
	    # host
	    #
	    # In case of distributed transaction, it is forbidden to subscribe to a
	    # proxy without having subscribed to the proxied object first. This
	    # method will thus subscribe to both at the same time. Peer#subscribe
	    # is supposed to do the same
	    def subscribe_plan_object(object)
		if Transactions::Proxy === object && object.__getobj__.self_owned?
		    subscribe_plan_object(object.__getobj__)
		end
		set_relations_commands(object)
	    end

	    # The peer wants to subscribe to our main plan
	    def subscribe_plan(sibling)
		added_sibling(Roby.plan.remote_id, sibling)
		peer.transmit(:subscribed_plan, Roby.plan.remote_id)
		subscribe(Roby.plan)
	    end

	    # Called by our peer because it has subscribed us to its main plan
	    def subscribed_plan(remote_plan_id)
		peer.proxies[remote_plan_id] = Roby.plan
		peer.remote_plan = remote_plan_id
	    end

	    # Subscribe the remote peer to changes on +object+. +object+ must be
	    # an object owned locally.
	    def subscribe(m_object)
		if !(local_object = peer.local_object(m_object, false))
		    raise NotOwner, "no object for #{m_object}"
		elsif !local_object.self_owned?
		    raise NotOwner, "not owner of #{local_object}"
		end

		# We put the subscription process outside the communication
		# thread so that the remote peer can send back the siblings it
		# has created
		execute do
		    peer.transmit(:subscribed, [local_object])

		    case local_object
		    when PlanObject
			if !local_object.root_object?
			    raise ArgumentError, "cannot subscribe to non-root objects"
			end
			subscribe_plan_object(local_object)

		    when Plan
			tasks, events = local_object.known_tasks, local_object.free_events
			tasks.delete_if    { |t| !t.distribute? }
			events.delete_if   { |t| !t.distribute? }

			peer.transmit(:discover_plan, local_object, tasks, events)
			tasks.each  { |obj| subscribe_plan_object(obj) }
			events.each { |obj| subscribe_plan_object(obj) }
		    end
		    local_object.remote_id
		end
	    end
	    
	    # Called by the remote host because it has subscribed us to a plan
	    # (a set of tasks and events).
	    def discover_plan(marshalled_plan, m_tasks, m_events)
		plan = peer.local_object(marshalled_plan)
		Distributed.update(plan) do
		    peer.local_object(m_tasks)
		    peer.local_object(m_events)
		end
		nil
	    end

	    # Called by the remote peer to announce that it has created the
	    # given siblings. +siblings+ is a remote_drbobject => local_object
	    # hash
	    #
	    # It is also used by BasicObject#sibling_of to register a new
	    # sibling
	    def added_sibling(local_id, remote_id)
		local_id.local_object.add_sibling_for(peer, remote_id)
		nil
	    end

	    # Called by the remote peer to announce that it has removed the
	    # given siblings. +objects+ is the list of local objects.
	    #
	    # It is also used by BasicObject#forget_peer to remove references
	    # to an old sibling
	    def removed_sibling(local_id, remote_id)
		local_object = local_id.local_object
		sibling = local_object.remove_sibling_for(peer, remote_id)

		# It is fine to remove a sibling twice: you nay for instance
		# decide in both sides that the sibling should be removed (for
		# instance during the disconnection process)
		if sibling && sibling != remote_id
		    raise "removed sibling #{sibling} for #{local_id} on peer #{peer} does not match the provided remote id (#{remote_id})"
		end

		unless local_object.remotely_useful?
		    Distributed.removed_objects.delete(local_object)
		end
	    end

	    # Called by the remote peer to announce that is has subscribed us to +objects+
	    def subscribed(objects)
		# Register the subscription
		objects.each do |object|
		    peer.subscriptions << peer.remote_object(object)
		end
		# Create the proxies
		peer.local_object(objects)
		nil
	    end

	    # Sends to the peer the set of relations needed to copy the state of +plan_object+
	    # on the remote peer.
	    def set_relations_commands(plan_object)
		peer.transmit(:set_relations, plan_object, Distributed.relations_of(plan_object))

		if plan_object.respond_to?(:each_plan_child)
		    plan_object.each_plan_child do |plan_child|
			peer.transmit(:set_relations, plan_child, Distributed.relations_of(plan_child))
		    end
		end
	    end

	    # Sets the relation of +objects+ according to the description in +relations+.
	    # See #relations_of for how +relations+ is formatted
	    #
	    # Note that any relation not listed in +relations+ will actually be
	    # *removed* from the plan. Therefore, if +relations+ is empty, then
	    # all relations of +object+ are removed.
	    def set_relations(object, relations)
		object    = peer.local_object(object)
		relations = peer.local_object(relations)

		Distributed.update(object.root_object) do
		    all_parents  = Hash.new { |h, k| h[k] = ValueSet.new }
		    all_children = Hash.new { |h, k| h[k] = ValueSet.new }
		    
		    # Add or update existing relations
		    relations.each_slice(3) do |graph, parents, children|
			all_objects = parents.map { |p, _| p } + children.map { |c, _| c }
			Distributed.update_all(all_objects) do
			    parents.each_slice(2) do |parent, info|
				next unless parent
				all_parents[graph] << parent

				if graph.linked?(parent, object)
				    parent[object, graph] = info
				else
				    Distributed.update(parent.root_object) do
					parent.add_child_object(object, graph, info)
				    end
				end
			    end
			    children.each_slice(2) do |child, info|
				next unless child
				all_children[graph] << child

				if graph.linked?(object, child)
				    object[child, graph] = info
				else
				    Distributed.update(child.root_object) do
					object.add_child_object(child, graph, info)
				    end
				end
			    end
			end
		    end

		    Distributed.each_object_relation(object) do |rel|
			# Remove relations that do not exist anymore
			#
			# If the other end of this relation cannot be seen by
			# our remote peer, keep it: it means that the relation
			# is a local-only annotation this pDB has added to the
			# task
			(object.parent_objects(rel).to_value_set - all_parents[rel]).each do |p|
			    # See comment above
			    next unless p.distribute?
			    Distributed.update_all([p.root_object, object.root_object]) do
				p.remove_child_object(object, rel)
			    end
			end
			(object.child_objects(rel).to_value_set - all_children[rel]).each do |c|
			    # See comment above
			    next unless c.distribute?
			    Distributed.update_all([c.root_object, object.root_object]) do
				object.remove_child_object(c, rel)
			    end
			end
		    end
		end

		nil
	    end

	end

	class Peer
	    # The set of remote objects we *want* notifications on, as
	    # RemoteID objects. This does not include automatically susbcribed
	    # objects, but only those explicitely subscribed to by calling
	    # Peer#subscribe
	    #
	    # See also #subscribe, #subscribed? and #unsubscribe
	    #
	    #--
	    # DO NOT USE a ValueSet here. RemoteIDs must be compared using #==
	    #++
	    attribute(:subscriptions) { Set.new }

	    # Explicitely subscribe to #object
	    #
	    # See also #subscriptions, #subscribed? and #unsubscribe
	    def subscribe(object)
		while object.respond_to?(:__getobj__)
		    object = object.__getobj__
		end

		if remote_object = (remote_object(object) rescue nil)
		    if !subscriptions.include?(remote_object)
			remote_object = nil
		    end
		end

		unless remote_object
		    remote_sibling = object.sibling_on(self)
		    remote_object = call(:subscribe, remote_sibling)
		    synchro_point
		end
		local_object = local_object(remote_object)
	    end

	    # Make our peer subscribe to +object+
	    def push_subscription(object)
		local.subscribe(object)
		synchro_point
	    end

	    # The RemoteID for the peer main plan
	    attr_accessor :remote_plan

	    # Subscribe to the remote plan
	    def subscribe_plan
		call(:subscribe_plan, connection_space.plan.remote_id)
		synchro_point
	    end

	    # Unsubscribe from the remote plan
	    def unsubscribe_plan
		proxies.delete(remote_plan)
		subscriptions.delete(remote_plan)
		if connected?
		    call(:removed_sibling, @remote_plan, connection_space.plan.remote_id)
		end
	    end
	    
	    def subscribed_plan?; remote_plan && subscriptions.include?(remote_plan) end

	    # True if we are explicitely subscribed to +object+. Automatically
	    # subscribed objects will not be included here, but
	    # BasicObject#updated? will return true for them
	    #
	    # See also #subscriptions, #subscribe and #unsubscribe
	    def subscribed?(object)
		subscriptions.include?(remote_object(object))
	    rescue RemotePeerMismatch
		false
	    end

	    # Remove an explicit subscription. See also #subscriptions,
	    # #subscribe and #subscribed?
	    #
	    # See also #subscriptions, #subscribe and #subscribed?
	    def unsubscribe(object)
		subscriptions.delete(remote_object(object))
	    end
	end
    end
end

