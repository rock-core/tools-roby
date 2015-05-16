module Roby
    module Distributed
	# Module included in objects distributed across multiple pDBs
	module DistributedObject
	    attribute(:mutex) { Mutex.new }
	    attribute(:synchro_call) { ConditionVariable.new }

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
			raise OwnershipError, "not object owner"
		    end

		    call_siblings(:add_owner, self, peer)
		    added_owner(peer)
		else
		    owners << peer
		    if plan
			plan.task_index.add_owner(self, peer)
		    end
		    Distributed.debug { "added owner to #{self}: #{owners.to_a}" }
		end
	    end
	    def added_owner(peer); super if defined? super end

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
		    removed_owner(peer)
		    if plan
			plan.task_index.remove_owner(self, peer)
		    end
		    Distributed.debug { "removed owner to #{self}: #{owners.to_a}" }
		end
		nil
	    end
	    def prepare_remove_owner(peer); super if defined? super end
	    def removed_owner(peer); super if defined? super end

	    def owner=(peer)
		add_owner(peer)
		owners.each do |owner|
		    remove_owner(owner) unless owner == peer
		end
	    end


	    def call_siblings(m, *args)
		Distributed.call_peers(updated_peers.dup << Distributed, m, *args)
	    end

	    def call_owners(*args) # :nodoc:
		raise OwnershipError, "not owner" if !self_owned?
		    
		if owners.any? { |peer| !has_sibling_on?(peer) }
		    raise InvalidRemoteOperation, "cannot do #{args} if the object is not distributed on all its owners"
		end

		Distributed.call_peers(owners, *args)
	    end
	end

	# Calls +args+ on all peers and returns a { peer => return_value } hash
	# of all the values returned by each peer
	def self.call_peers(calling, m, *args)
	    Distributed.debug { "distributed call of #{m}(#{args}) on #{calling}" }

	    # This is a tricky procedure. Let's describe what is done here:
	    # * we send the required message to the peers listed in +calling+,
	    #   and wait for all of them to have finished
	    # * since there is a coordination requirement, once a peer have
	    #   processed its call we stop processing any of the messages it 
	    #   sends. We therefore block the RX thread of this peer using 
	    #   the block_communication condition variable

	    result              = Hash.new
	    call_local          = calling.include?(Distributed)
	    synchro, mutex      = Roby.condition_variable(true)

	    mutex.synchronize do
		waiting_for = calling.size
		waiting_for -= 1 if call_local

		calling.each do |peer| 
		    next if peer == Distributed

		    callback = Proc.new do |peer_result|
			mutex.synchronize do
			    result[peer] = peer.local_object(peer_result)
			    waiting_for -= 1
			    Distributed.debug { "reply for #{m}(#{args.join(", ")}) from #{peer}, #{waiting_for} remaining" }
			    if waiting_for == 0
				synchro.broadcast
			    end
			    peer.disable_rx
			end
		    end
		    peer.queue_call false, m, args, callback, Thread.current
		end

		while waiting_for != 0
		    Distributed.debug "waiting for our peers to complete the call"
		    synchro.wait(mutex) 
		end
	    end

	    if call_local
		Distributed.debug "processing locally ..."
		result[Distributed] = Distributed.call(m, *args)
	    end
	    result

	ensure
	    for peer in calling
		peer.enable_rx if peer != Distributed
	    end
	    Roby.return_condition_variable(synchro, mutex)
	end
    end
end

