module Roby
    module Distributed
	# RemoteID objects are used in dRoby to reference objects on other
	# peers. It uses the same mechanisms that DRbObject but is not
	# converted back into a local object automatically, and does not allow
	# to call remote methods on a remote object.
	class RemoteID
	    # The URI of the DRb server
	    attr_reader :uri
	    # The reference ID of the object on the DRb server
	    attr_reader :ref

	    # Creates a new RemoteID with the given URI and ID
	    def initialize(uri, ref)
		@uri, @ref = uri, ref.to_int
		@hash = [uri, ref].hash
	    end

	    def _dump(lvl) # :nodoc:
	       	@__droby_marshalled__ ||= Marshal.dump([uri, ref]) 
	    end
	    def self._load(str) # :nodoc:
	       	new(*Marshal.load(str)) 
	    end

	    def ==(other) # :nodoc:
		other.kind_of?(RemoteID) && other.ref == ref && other.uri == uri
	    end
	    alias :eql? :==
	    attr_reader :hash

	    # True if this object references a local object
	    def local?; DRb.here?(uri) end
	    # If this ID references a local object, returns it. Otherwise, returns self.
	    def local_object
		if DRb.here?(uri)
		    DRb.to_obj(ref)
		else
		    self
		end
	    end

	    def to_s(peer = nil)
		if peer
		    "0x#{Object.address_from_id(ref).to_s(16)}@#{peer.name}"
		else
		    "0x#{Object.address_from_id(ref).to_s(16)}@#{uri}"
		end
	    end
	    def inspect; to_s end
	    def pretty_print(pp); pp.text to_s end

	    def to_local(manager, create)
		object = local_object
		if object.kind_of?(RemoteID)
		    if local_proxy = manager.proxies[object]
			return manager.proxy_setup(local_proxy)
		    elsif !create
			return
		    elsif manager.removing_proxies.has_key?(object)
			marshalled_object = manager.removing_proxies[object].last
			marshalled_object.remote_siblings.delete(Distributed.droby_dump)
			marshalled_object.remote_siblings[manager.droby_dump] = self

			if marshalled_object.respond_to?(:plan) && !marshalled_object.plan
			    # Take care of the "proxy is GCed while the manager
			    # sends us messages about it" case. In this case,
			    # the object has already been removed when it is
			    # marshalled (#plan == nil).
			    #
			    # This cannot happen in transactions: it only happens
			    # in plans where one side can remove an object while
			    # the other side is doing something on it
			    marshalled_object.instance_variable_set(:@plan, Roby.plan)
			end

			object = manager.local_object(marshalled_object)

			if object.respond_to?(:plan) && !object.plan
			    raise "#{object} has no plan !"
			end

			return object
		    end
		    raise MissingProxyError.new(self), "#{self} has no proxy"
		else
		    object
		end
	    end

	    private :remote_id

	    # Returns the RemoteID object for +obj+. This is actually
	    # equivalent to obj.remote_id
	    def self.from_object(obj)
		Roby::Distributed::RemoteID.new(DRb.current_server.uri, DRb.to_id(obj) || 0)
	    end

	    # Creates a DRbObject corresponding to the object referenced by this RemoteID
	    def to_drb_object
		DRbObject.new_with(uri, (ref == 0 ? nil : ref))
	    end
	end
    end
end

