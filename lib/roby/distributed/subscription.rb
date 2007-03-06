
module Roby
    module Distributed
	class << self
	    def each_subscribed_peer(*objects)
		return if objects.any? { |o| !o.distribute? }
		peers.each do |name, peer|
		    next unless peer.connected?
		    if objects.any? { |o| peer.need_updates?(o) }
			yield(peer) 
		    end
		end
	    end
	end

	class PeerServer
	    # Called by the remote host because it has subscribed us to 
	    # a set of tasks in a plan
	    def subscribed_plan(marshalled_plan, missions, known_tasks, free_events)
		plan = peer.local_object(marshalled_plan)
		Distributed.update([plan]) do
		    subscriptions.merge(known_tasks = peer.local_object(known_tasks))
		    subscriptions.merge(free_events = peer.local_object(free_events))
		    plan.discover(known_tasks)
		    plan.discover(free_events)
		end
		nil
	    end

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
		    subscribe(object.__getobj__)
		end
		set_relations_commands(object)
	    end

	    # Subscribe the remote peer to changes on +object+. +object+ must be
	    # an object owned locally.
	    def subscribe(object)
		return unless object = peer.local_object(object)
		return if subscribed?(object)
		unless object.self_owned?
		    raise "#{remote_name} is trying to subscribe to #{object} which is not owned by us"
		end

		subscriptions << object
		peer.transmit(:subscribed, [object])

		case object
		when PlanObject
		    subscribe_plan_object(object)

		when Plan
		    missions, tasks, events = object.missions, object.known_tasks, object.free_events
		    tasks.delete_if    { |t| !t.distribute? }
		    missions.delete_if { |t| !t.distribute? }
		    events.delete_if   { |t| !t.distribute? }

		    if object.kind_of?(Transaction)
			tasks = tasks.to_a
			tasks.dup.each do |t| 
			    if Transactions::Proxy === t && t.__getobj__.self_owned?
				tasks.unshift t.__getobj__ # put real objects first
			    end
			end
		    end

		    peer.transmit(:subscribed_plan, object, missions, tasks, events)
		    subscriptions.merge(tasks.to_value_set)
		    subscriptions.merge(events)

		    tasks.each  { |obj| subscribe_plan_object(obj) }
		    events.each { |obj| subscribe_plan_object(obj) }
		end

		nil
	    end

	    # Called by the remote peer to announce that is has subscribed us to +objects+
	    def subscribed(objects)
		objects = objects.map do |obj| 
		    raise "not a root object" if obj.respond_to?(:root_object?) && !obj.root_object?
		    obj.remote_object
		end
		peer.subscriptions.merge(objects)
		nil
	    end

	    # The peer asks to be unsubscribed from +object+
	    def unsubscribe(object)
		local_object = peer.local_object(object, false)
		if !local_object
		    return
		elsif !subscriptions.include?(local_object)
		    raise ArgumentError, "#{peer.remote_name} is not subscribed to #{object}"
		end

		subscriptions.delete(local_object)
		nil
	    end

	    # Check if changes to +object+ should be notified to this peer
	    def subscribed?(object)
		subscriptions.include?(object)
	    end

	    # Returns the commands to be fed to #set_relations in order to copy
	    # the state of plan_object on the remote peer
	    #
	    # The returned relation sets can be empty if the plan object does not
	    # have any relations. Since the goal is to *copy* the graph relations...
	    def set_relations_commands(plan_object)
		peer.transmit(:set_relations, plan_object, relations_of(plan_object))

		if plan_object.respond_to?(:each_plan_child)
		    plan_object.each_plan_child do |plan_child|
			# Send event even if +result+ is empty, so that relations
			# are removed if needed on the other side
			peer.transmit(:set_relations, plan_child, relations_of(plan_child))
		    end
		end
	    end

	    # Receive the list of relations of +object+. Relations must be formatted
	    # like #relations_of does
	    def set_relations(object, relations)
		return unless object = peer.local_object(object)
		relations = peer.local_object(relations)

		Distributed.update([object.root_object]) do
		    all_parents  = Hash.new { |h, k| h[k] = ValueSet.new }
		    all_children = Hash.new { |h, k| h[k] = ValueSet.new }
		    
		    # Add or update existing relations
		    relations.each_slice(3) do |graph, parents, children|
			parents.each_slice(2) do |parent, info|
			    next unless parent
			    all_parents[graph] << parent

			    if graph.linked?(parent, object)
				parent[object, graph] = info
			    else
				Distributed.update([parent.root_object]) do
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
				Distributed.update([child.root_object]) do
				    object.add_child_object(child, graph, info)
				end
			    end
			end
		    end

		    Distributed.each_object_relation(object) do |rel|
			# Remove relations that do not exist anymore
			(object.parent_objects(rel) - all_parents[rel]).each do |p|
			    Distributed.update([p.root_object, object.root_object]) do
				p.remove_child_object(object, rel)
			    end
			end
			(object.child_objects(rel) - all_children[rel]).each do |c|
			    Distributed.update([c.root_object, object.root_object]) do
				object.remove_child_object(c, rel)
			    end
			end
		    end
		end

		nil
	    end

	end

	class Peer
	    # The set of remote objects we are subscribed to. This is a set of
	    # DRbObject
	    #
	    # DO NOT USE a ValueSet here. We use DRbObjects to track subscriptions
	    # on this side, and they must be compared using #==
	    attribute(:subscriptions) { Set.new }

	    # Subscribe to +marshalled+.	
	    def subscribe(object)
		remote_object = remote_object(object)

		unless subscriptions.include?(remote_object)
		    call(:subscribe, remote_object)
		end
		proxies[remote_object]
	    end

	    # True if we are subscribed to +remote_object+ on the peer
	    def subscribed?(object)
		subscriptions.include?(remote_object(object))
	    end

	    # Unsubscribe ourselves from +object+. 	
	    def unsubscribe(object)
		remote_object, local_object = objects(object)
		case local_object
		when PlanObject
		    if linked_to_local?(local_object)
			raise InvalidRemoteOperation, "cannot unsubscribe to a task still linked to local tasks"
		    end
		end

		call(:unsubscribe, remote_object)
		synchro_point
		subscriptions.delete(remote_object)
	    end
	end
    end
end

