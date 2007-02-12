
module Roby
    module Distributed
	class << self
	    def each_subscribed_peer(*objects)
		return if objects.any? { |o| !o.distribute? }
		peers.each do |name, peer|
		    next unless peer.connected?
		    next if objects.any? { |o| !o.has_sibling?(peer) }
		    yield(peer) if objects.any? { |o| peer.local.subscribed?(o) || peer.owns?(o) }
		end
	    end
	end

	class PeerServer
	    # Called by the remote host because it has subscribed us to 
	    # a set of tasks in a plan
	    def subscribed_plan(marshalled_plan, missions, known_tasks)
		plan = peer.local_object(marshalled_plan)
		Distributed.update([plan]) do
		    known_tasks.each do |t| 
			peer.subscriptions << t.remote_object
			obj = peer.local_object(t)
			plan.discover(obj)
		    end
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
	    #
	    # Returns a [subscribed, init] pair, where +subscribed+ is the set of
	    # objects actually added to the list of subscriptions, and +init+ an
	    # array which is to be fed to PeerServer#demux_local by the caller.
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
		    if object.kind_of?(Transaction)
			missions, tasks = [object.missions(true), object.known_tasks(true)]
			tasks.delete_if    { |t| !t.distribute? }
			tasks = tasks.to_a
			tasks.dup.each do |t| 
			    if Transactions::Proxy === t && t.__getobj__.self_owned?
				tasks.unshift t.__getobj__ # put real objects first
			    end
			end
		    else
			missions, tasks = [object.missions, object.known_tasks]
			tasks.delete_if    { |t| !t.distribute? }
		    end

		    missions.delete_if { |t| !t.distribute? }
		    peer.transmit(:subscribed_plan, object, missions, tasks)
		    tasks.each { |t| subscribe(t) }
		end

		nil
	    end

	    # Called by the remote peer to announce that is has subscribed us to +objects+
	    def subscribed(objects)
		peer.subscriptions.merge(objects.map { |obj| obj.remote_object })
		nil
	    end

	    # The peer asks to be unsubscribed from +object+
	    def unsubscribe(object)
		object = peer.local_object(object)
		if !subscriptions.include?(object)
		    raise ArgumentError, "#{peer.remote_name} is not subscribed to #{object}"
		end
		subscriptions.delete(object)
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

		if plan_object.respond_to?(:each_event)
		    plan_object.each_event do |ev|
			# Send event even if +result+ is empty, so that relations
			# are removed if needed on the other side
			peer.transmit(:set_relations, ev, relations_of(ev))
		    end
		end
	    end

	    # Receive the list of relations of +object+. The relations are given in
	    # an array like [[graph, from, to, info], [...], ...]
	    def set_relations(object, relations)
		return unless object = peer.local_object(object)
		Distributed.update([object]) do
		    parents  = Hash.new { |h, k| h[k] = Array.new }
		    children = Hash.new { |h, k| h[k] = Array.new }
		    
		    # Add or update existing relations
		    relations.each do |graph, graph_relations|
			graph_relations.each do |args|
			    apply(args) do |from, to, info|
				if !from || !to
				    next
				elsif to == object
				    parents[graph]  << from
				elsif from == object
				    children[graph] << to
				else
				    raise ArgumentError, "trying to set a relation #{from.inspect} -> #{to.inspect} in which self(#{object.inspect}) in neither parent nor child"
				end

				if graph.linked?(from, to)
				    from[to, graph] = info
				else
				    Distributed.update([from.root_object, to.root_object]) do
					from.add_child_object(to, graph, info)
				    end
				end
			    end
			end
		    end

		    Distributed.each_object_relation(object) do |rel|
			# Remove relations that do not exist anymore
			(object.parent_objects(rel) - parents[rel]).each do |p|
			    Distributed.update([p.root_object, object.root_object]) do
				p.remove_child_object(object, rel)
			    end
			end
			(object.child_objects(rel) - children[rel]).each do |c|
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

		if subscriptions.include?(remote_object)
		    yield if block_given?
		elsif block_given?
		    transmit(:subscribe, remote_object) do
			yield if block_given?
		    end
		else
		    transmit(:subscribe, remote_object)
		end
	    end

	    # True if we are subscribed to +remote_object+ on the peer
	    def subscribed?(object)
		subscriptions.include?(remote_object(object))
	    end

	    # Clears all relations that should be removed because we unsubscribed
	    # from +proxy+
	    def remove_unsubscribed_relations(local_object) # :nodoc:
		Distributed.update([local_object]) do
		    local_object.related_tasks.each do |task|
			if !task.subscribed?
			    local_object.remove_relations(task)
			    delete(task, true) if unnecessary?(task)
			end
		    end
		    if unnecessary?(local_object)
			delete(local_object, true)
		    end
		end
	    end

	    # Unsubscribe ourselves from +marshalled+. If +remove_object+ is true,
	    # the local proxy for this object is removed from the plan as well
	    def unsubscribe(object, remove_object = true)
		remote_object, local_object = objects(object)

		case local_object
		when PlanObject
		    if linked_to_local?(local_object)
			raise InvalidRemoteOperation, "cannot unsubscribe to a task still linked to local tasks"
		    end

		    transmit(:unsubscribe, remote_object) do
			subscriptions.delete(remote_object)
			if remove_object
			    remove_unsubscribed_relations(local_object)
			end
			yield if block_given?
		    end

		else
		    transmit(:unsubscribe, remote_object) do
			subscriptions.delete(remote_object)
			yield if block_given?
		    end
		end
	    end
	end
    end
end

