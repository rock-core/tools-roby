module Roby
    module Distributed
	class InvalidRemoteOperation < RuntimeError; end
	class OwnershipError         < InvalidRemoteOperation; end
	class NotOwner               < OwnershipError; end

	class RemotePeerMismatch     < RuntimeError; end

	class InvalidRemoteTaskOperation < InvalidRemoteOperation
	    attr_reader :task
	    def initialize(task); @task = task end
	end

	# Module included in objects that are located on this pDB
	module LocalObject
	    def owners; @owners ||= [Roby::Distributed.remote_id].to_set end
	    def self_owned?; true end
	    def has_sibling?(peer); true end
	    def subscribed?; true end
	    
	    module ClassExtension
		# Does the object of this class should be sent to remote hosts ?
		def distribute?; !(@distribute == false) end
		# Call to make the object of this class local to this host
		def local_object; @distribute = false end
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

	    def remote_object(peer_id)
		if peer_id == peer_id then @remote_object
		else 
		    raise RemotePeerMismatch, "#{self} has no known sibling on #{peer_id} (#{@peer_id})"
		end
	    end

	    def distribute?; true end
	    def self_owned?; false end
	    def has_sibling?(peer); true end
	    def subscribed?; remote_peer.subscribed?(@remote_object) end

	    def ==(obj)
		obj.kind_of?(RemoteObject) && 
		    peer_id == obj.peer_id &&
		    @remote_object == obj.remote_object(peer_id)
	    end
	end

	# Module included in objects distributed across multiple pDBs
	module DistributedObject
	    def self_owned?
		owners.include?(Distributed.remote_id)
	    end
	    def distribute?; true end
	    def subscribed?; self_owned? end

	    def has_sibling?(peer)
		!owners.include?(peer.remote_id) ||
		    remote_siblings.has_key?(peer.remote_id)
	    end

	    attribute(:remote_siblings) { Hash.new }
	    def remote_object(peer_id)
		if sibling = remote_siblings[peer_id] then sibling
		else 
		    raise RemotePeerMismatch, "#{self} has no known sibling on #{peer_id}"
		end
	    end
	    
	    # Makes this transaction owned by the local DB. This is equivalent
	    # to trsc.self_owned = true
	    def self_owned; self.self_owned = true end

	    # Adds or removes the local DB from the list of owners. This is
	    # equivalent to calling add_peer(Distributed.state) and
	    # remove_peer(Distributed.state)
	    def self_owned=(flag)
		if flag then add_owner(Distributed)
		else remove_owner(Distributed)
		end
	    end
	    
	    def ==(other)
		super || (other.kind_of?(DistributedObject) && 
		    remote_siblings.any? { |peer_id, obj| other.remote_siblings[peer_id] == obj })
	    end
	end
    end
end

