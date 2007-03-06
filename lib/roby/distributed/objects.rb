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
		    return true if peer.local.subscribed?(root_object)
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
	    # If we know about some sibling on +peer+. It is always true for
	    # this pDB (object.has_sibling?(Distributed) always returns true)
	    def has_sibling?(peer); peer == remote_peer || peer == Distributed end

	    # True if the local pDB gets informed about the updates of this
	    # object
	    def subscribed?; remote_peer.subscribed?(root_object.remote_object(remote_peer)) end
	    # True if the local pDB needs to keep this object because of its
	    # connection with other peers
	    def needed?; root_object.subscribed? end
	end

	# Module included in objects distributed across multiple pDBs
	module DistributedObject
	    attribute(:mutex) { Mutex.new }
	    attribute(:synchro_call) { ConditionVariable.new }
	    attribute(:remote_siblings) { Hash.new }

	    def distribute?; true end
	    def needed?; subscribed? end
	    def subscribed?; self_owned? || owners.any? { |peer| peer.subscribed?(root_object) } end
	    def local?; owners.size == 1 && owners.first == Distributed end

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
	    
	    def self_owned?; owners.include?(Distributed) end

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

