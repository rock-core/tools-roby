module Roby
    module Distributed
	# Module included in objects distributed across multiple pDBs
	module DistributedObject
	    attribute(:mutex) { Mutex.new }
	    attribute(:synchro_call) { ConditionVariable.new }
	    attribute(:remote_siblings) { Hash.new }

	    def distribute?; true end

	    # Makes this object owned by the local DB. This is equivalent to
	    # object.self_owned = true
	    def self_owned; self.self_owned = true end

	    # Adds or removes the local DB from the list of owners. This is
	    # equivalent to calling add_peer(Distributed) and
	    # remove_peer(Distributed)
	    def self_owned=(flag)
		if flag then add_owner(Distributed)
		else remove_owner(Distributed)
		end
	    end
	    
	    # Add the Peer +peer+ to the list of owners
	    def add_owner(peer, distributed = true)
		return if owners.include?(peer)
		if distributed 
		    if !self_owned?
			raise NotOwner, "not object owner"
		    end

		    call_siblings(:add_owner, self, peer)
		else
		    owners << peer
		    Distributed.debug { "added owner to #{self}: #{owners.to_a}" }
		end
	    end

	    # Removes +peer+ from the list of owners. Raises OwnershipError if
	    # there are modified tasks in this transaction which are owned by
	    # +peer+
	    def remove_owner(peer, distributed = true)
		return unless owners.include?(peer)

		if distributed
		    results = call_siblings(:prepare_remove_owner, self, peer)
		    if error = results.values.find { |error| error }
			raise error
		    end
		    call_siblings(:remove_owner, self, peer)
		else
		    owners.delete(peer)
		    Distributed.debug { "removed owner to #{self}: #{owners.to_a}" }
		end
		nil
	    end


	    def call_siblings(*args)
		Distributed.call_peers(mutex, synchro_call, remote_siblings.keys << Distributed, *args)
	    end

	    def call_owners(*args) # :nodoc:
		raise NotOwner, "not owner" if !self_owned?
		    
		if owners.any? { |peer| !has_sibling?(peer) }
		    raise InvalidRemoteOperation, "cannot do #{args} if the object is not distributed on all its owners"
		end

		Distributed.call_peers(mutex, synchro_call, owners, *args)
	    end
	end

	# Calls +args+ on all peers and returns a { peer => return_value } hash
	# of all the values returned by each peer
	def self.call_peers(mutex, synchro, calling, *args)
	    call_local = calling.include?(Distributed)

	    result = Hash.new
	    mutex.synchronize do
		waiting_for = calling.size
		waiting_for -= 1 if call_local

		calling.each do |peer| 
		    next if peer == Distributed
		    peer.transmit(*args) do |peer_result|
			mutex.synchronize do
			    result[peer] = peer_result
			    waiting_for -= 1
			    if waiting_for == 0
				synchro.broadcast
			    end
			end
		    end
		end

		synchro.wait(mutex) unless waiting_for == 0
	    end

	    if call_local
		result[Distributed] = Distributed.call(*args)
	    end
	    result
	end


	class PeerServer
	    # Creates a sibling for +marshalled_object+, which already exists
	    # on our peer
	    def create_sibling(marshalled_object)
		object_remote_id = peer.remote_object(marshalled_object)
		if sibling = peer.proxies[object_remote_id]
		    raise ArgumentError, "#{marshalled_object} has already a sibling (#{sibling})"
		end

		sibling = marshalled_object.sibling(peer)
		sibling.remote_siblings[peer] = object_remote_id
		peer.proxies[object_remote_id] = sibling

		subscriptions << sibling
		peer.subscriptions << object_remote_id

		marshalled_object.created_sibling(peer, sibling)
		sibling
	    end
	end

	class Peer
	    # Creates a sibling for +object+ on the peer, and returns the corresponding
	    # DRbObject
	    def create_sibling(object)
		unless object.kind_of?(DistributedObject)
		    raise TypeError, "cannot create a sibling for a non-distributed object"
		end

		marshalled_sibling = call(:create_sibling, object)
		sibling_id = marshalled_sibling.remote_object
		object.remote_siblings[self] = sibling_id
		proxies[sibling_id] = object

		subscriptions << marshalled_sibling.remote_object
		Roby::Control.synchronize do
		    local.subscribe(object)
		end

		call(:synchro_point)
	    end
	end
    end
end

