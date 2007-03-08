module Roby
    class BasicObject
	# The set of Peer objects which own this object
	def owners; [Distributed] end
	# True if we own this object
	def self_owned?; owners.include?(Distributed) end

	# Attribute which overrides the #distribute attribute on object classes
	attr_writer :distribute
	# True if this object can be seen by remote hosts
	def distribute?
	    @distribute || (@distribute.nil? && self.class.distribute?)
	end

	# True if instances of this class should be seen by remote hosts
	def self.distribute?; !(@distribute == false) end
	# Call to make the object of this class never seen by remote hosts
	def self.local_only; @distribute = false end
	
	# The peer => remote_object hash of known siblings for this peer: if
	# there is a representation of this object on a peer, then
	# +remote_siblings+ includes it
	attribute(:remote_siblings) { Hash.new }

	# Returns the object representation of 
	def sibling(peer_id)
	    if sibling = remote_siblings[peer_id] then sibling
	    elsif peer_id == Roby::Distributed then self
	    else 
		raise RemotePeerMismatch, "#{self} has no known sibling on #{peer_id}"
	    end
	end

	# True if this object is updated by the peers owning it
	def subscribed?; self_owned? || owners.any? { |peer| remote_siblings[peer] } end
	# True if +peer+ will send us updated about this object
	def subscribed_on?(peer); remote_siblings[peer] && peer.owns?(self) end
	# If this object is used by our peers
	def remotely_useful?; self_owned? && !remote_siblings.empty?  end
	
	# True if this object can be modified in the current context
	def read_write?
	    Distributed.updating?([root_object]) || self_owned? 
	end
    end
end

