module Roby
    module Distributed
	class InvalidRemoteOperation < RuntimeError; end
	class RemotePeerMismatch     < RuntimeError; end

	class InvalidRemoteTaskOperation < InvalidRemoteOperation
	    attr_reader :task
	    def initialize(task); @task = task end
	end

	# Module included in objects that are located on this pDB
	module LocalObject
	    def owners; [Distributed] end

	    def local?; true end
	    def self_owned?; true end
	    def has_sibling?(peer); peer == Distributed end
	    def subscribed?; true end
	    def needed?
		Distributed.peers.each_value do |peer|
		    return true if peer.local.subscriptions.include?(self)
		end
		false
	    end
	    def remote_siblings; {} end
	    
	    module ClassExtension
		# Does the object of this class should be sent to remote hosts ?
		def distribute?; !(@distribute == false) end
		# Call to make the object of this class local to this host
		def local_object; @distribute = false end
	    end
	    
	    def remote_object(peer)
		if peer == Roby::Distributed then self
		else
		    raise RemotePeerMismatch, "#{self} is local"
		end
	    end

	    # Attribute which overrides the #distribute attribute on object classes
	    attr_writer :distribute
	    # True if this object can be seen by remote hosts
	    def distribute?
		@distribute || (@distribute.nil? && self.class.distribute?)
	    end
	end

	# Module included in objects that are located on one single remote pDB
	module RemoteObject
	    # The remote Peer this object is located on
	    attr_reader :remote_peer
	    # The Peer ID
	    def peer_id; remote_peer.remote_id end

	    def local?; false end
	    # The peer => remote_object hash of known siblings for this peer
	    def remote_siblings; { remote_peer => @remote_object } end

	    # The DRbObject for the sibling of +self+ on +peer+
	    def remote_object(peer)
		if peer == remote_peer then @remote_object
		elsif peer == Roby::Distributed then self
		else 
		    raise RemotePeerMismatch, "#{self} has no known sibling on #{peer_id} (#{@peer_id})"
		end
	    end

	    # The list of owners for this object
	    def owners; [remote_peer] end

	    # If this object is seen by other pDBs
	    def distribute?; true end
	    # If this object is owned by us
	    def self_owned?; false end
	    # If we know about some sibling on +peer+. It is always true for this
	    # pDB (object.has_sibling?(Distributed) always returns true)
	    def has_sibling?(peer); peer == remote_peer || peer == Distributed end

	    # True if the local pDB gets informed about the updates of this
	    # object
	    def subscribed?; remote_peer.subscribed?(@remote_object) end
	    # True if the local pDB needs to keep this object because of its
	    # connection with other peers
	    def needed?;     subscribed? end
	end

	# Module included in objects distributed across multiple pDBs
	module DistributedObject
	    def self_owned?
		owners.include?(Distributed)
	    end
	    def distribute?; true end
	    def needed?; subscribed? end
	    def subscribed?; self_owned? || owners.any? { |peer| peer.subscribed?(self) } end
	    def local?; self_owned? end

	    def has_sibling?(peer)
		remote_siblings.has_key?(peer) || peer == Roby::Distributed
	    end

	    def remote_object(peer_id)
		if sibling = remote_siblings[peer_id] then sibling
		elsif peer_id == Roby::Distributed then self
		else 
		    raise RemotePeerMismatch, "#{self} has no known sibling on #{peer_id}"
		end
	    end
	    
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
	    
	    def ==(other)
		super || (other.kind_of?(DistributedObject) && 
		    remote_siblings.any? { |peer_id, obj| other.remote_siblings[peer_id] == obj })
	    end
	    
	    # Sends the provided command to all owners. If +ignore_missing+ is
	    # true, ignore the owners to which the transaction has not yet been
	    # proposed. Raises InvalidRemoteOperation if +ignore_missing+.
	    #
	    # Yields the value returned by the remote owners to the block
	    # inside the communication thread. +done+ is true for the last peer
	    # to reply.
	    def apply_to_owners(ignore_missing, *args) # :nodoc:
		if !ignore_missing
		    owners.each do |remote_id|
			if remote_id.kind_of?(DRbObject) && !remote_siblings.has_key?(remote_id)
			    raise InvalidRemoteOperation, "cannot do #{args} if the transaction is not distributed on all its owners"
			end
		    end
		end

		waiting_for = owners.size - 1
		result = Distributed.state.send(*args)
		yield(waiting_for == 0, result) if block_given?

		owners.each do |remote_id| 
		    next unless remote_siblings.include?(remote_id)
		    next unless remote_id.kind_of?(DRbObject)

		    Distributed.peer(remote_id).call(*args)
		    waiting_for -= 1
		    yield(waiting_for == 0, result) if block_given?
		end
	    end

	end
    end
end

