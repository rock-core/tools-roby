module Roby
    module Distributed
	module RemoteObject
	    attr_reader :peer_id
	    def remote_object(peer_id)
		if peer_id == @peer_id then @remote_object
		else 
		    raise RemotePeerMismatch, "#{self} has no known sibling on #{peer_id} (#{@peer_id})"
		end
	    end

	    def ==(obj)
		obj.kind_of?(RemoteObject) && 
		    peer_id == obj.peer_id &&
		    @remote_object == obj.remote_object(peer_id)
	    end
	end

	module DistributedObject
	    attribute(:remote_siblings) { Hash.new }
	    def remote_object(peer_id)
		if sibling = remote_siblings[peer_id] then sibling
		else 
		    raise RemotePeerMismatch, "#{self} has no known sibling on #{peer_id}"
		end
	    end
	    
	    def ==(other)
		super || (other.kind_of?(DistributedObject) && 
		    remote_siblings.any? { |peer_id, obj| other.remote_siblings[peer_id] == obj })
	    end
	end
    end
end

