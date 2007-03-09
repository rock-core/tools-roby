module Roby
    class RemotePeerMismatch     < RuntimeError; end

    class BasicObject
	# The set of Peer objects which own this object
	attribute(:owners) { [Distributed] }
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

	# True if we know about a sibling on +peer+
	def has_sibling_on?(peer)
	    peer == Roby::Distributed || remote_siblings.include?(peer)
	end

	# Returns the object representation of +self+ on +peer+. The returned
	# value is either a remote sibling (the DRbObject of the representation 
	# of +self+ on +peer+), or self if peer is Roby::Distributed
	def sibling_on(peer)
	    if sibling = remote_siblings[peer] then sibling
	    elsif peer == Roby::Distributed then self
	    else 
		raise RemotePeerMismatch, "#{self} has no known sibling on #{peer}"
	    end
	end

	# The DRbObject for this object
	def drb_object; @drb_object ||= DRbObject.new(self) end

	# Sets +remote_object+ as the remote siblings for +self+ on +peer+, and
	# notifies peer that +self+ is the remote siblings for +remote_object+
	def sibling_of(remote_object, peer)
	    if !distribute?
		raise "#{self} is local only"
	    end

	    add_sibling_for(peer, remote_object)
	    peer.transmit(:added_sibling, remote_object, drb_object)
	end

	# Called to tell us that we should not be involved with +peer+ anymore
	def forget_peer(peer)
	    if remote_object = remove_sibling_for(peer)
		if peer.connected?
		    peer.transmit(:removed_sibling, remote_object, drb_object) do
			yield if block_given?
		    end
		end
	    end
	end

	# Registers +remote_object+ as the sibling of +self+ on +peer+. Unlike
	# #sibling_of, do not notify the peer about it.
	def add_sibling_for(peer, remote_object)
	    if old_sibling = remote_siblings[peer]
		raise "#{self} has already a sibling for #{peer} (#{old_sibling})"
	    end

	    Roby.debug "added sibling #{remote_object} for #{self} on #{peer}"
	    remote_siblings[peer] = remote_object
	    peer.proxies[remote_object] = self
	end

	# Remove references about the sibling registered for +peer+ and returns it
	def remove_sibling_for(peer)
	    if remote_object = remote_siblings.delete(peer)
		peer.proxies.delete(remote_object)
		peer.subscriptions.delete(remote_object)
		Roby.debug "removed sibling #{remote_object} for #{self} on #{peer}"
		remote_object
	    end
	end

	# True if we explicitely want this object to be updated by our peers
	def subscribed?; owners.any? { |peer| peer.subscribed?(self) if peer != Distributed } end
	# True if this object is maintained up-to-date
	def updated?; self_owned? || owners.any?(&remote_siblings.method(:[])) end
	# True if +peer+ will send us updates about this object
	def updated_by?(peer); self_owned? || (remote_siblings[peer] && peer.owns?(self)) end
	# True if we shall send updates for this object on +peer+
	def update_on?(peer); (self_owned? || peer.owns?(self)) && remote_siblings[peer] end
	# The set of peers that will get updates of this object
	def updated_peers; remote_siblings.keys end
	# If this object is useful for our peers
	def remotely_useful?; self_owned? && !remote_siblings.empty?  end
	
	# True if this object can be modified in the current context
	def read_write?
	    Distributed.updating?([self]) || self_owned? 
	end
    end
end

