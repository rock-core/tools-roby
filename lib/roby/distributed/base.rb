require 'drb'

class RefCounting
    def initialize
	@values = Hash.new(0)
	@mutex  = Mutex.new
    end
    def ref?(obj); @mutex.synchronize { @values[obj] > 0 } end
    def deref(obj)
	@mutex.synchronize do
	    if (@values[obj] -= 1) == 0
		@values.delete(obj)
		return true
	    end
	end
	false
    end
    def ref(obj)
	@mutex.synchronize do
	    @values[obj] += 1
	end
    end
end

class Object
    # The Roby::Distributed::RemoteID for this object
    def remote_id
	@__droby_remote_id__ ||= Roby::Distributed::RemoteID.from_object(self)
    end
end

class DRbObject
    def to_s; inspect end
    # Converts this DRbObject into Roby::Distributed::RemoteID
    def remote_id
	@__droby_remote_id__ ||= Roby::Distributed::RemoteID.new(__drburi, __drbref)
    end
end

module Roby
    module Distributed
	class InvalidRemoteOperation < RuntimeError; end

	class InvalidRemoteTaskOperation < InvalidRemoteOperation
	    attr_reader :task
	    def initialize(task); @task = task end
	end

	extend Logger::Hierarchy
	extend Logger::Forward

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

	    def proxy(peer)
		object = local_object
		if object.kind_of?(RemoteID)
		    if local_proxy = peer.proxies[object]
			return peer.proxy_setup(local_proxy)
		    elsif marshalled_object = peer.removing_proxies.delete(object)
			marshalled_object.remote_siblings[peer.droby_dump] = self
			return peer.local_object(marshalled_object)
		    end
		    raise ArgumentError, "got a RemoteID which has no proxy"
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

	@updated_objects = ValueSet.new
	@allowed_remote_access = Array.new
	class << self
	    attr_reader :state
	    def state=(new_state)
		if log = logger
		    if new_state
			logger.progname = "Roby (#{new_state.name})"
		    else
			logger.progname = "Roby"
		    end
		end
		@state = new_state
	    end

	    def owns?(object); !state || state.owns?(object) end

	    # The set of objects we should temporarily keep because they are used
	    # in a callback mechanism (like a remote query or a trigger)
	    attribute(:keep) { RefCounting.new }

	    def keep_object?(local_object)
		local_object.remotely_useful? || 
		    local_object.subscribed? || 
		    Distributed.keep.ref?(local_object)
	    end

	    def keep?(local_object)
		return true if keep_object?(local_object)

		Roby::Distributed.each_object_relation(local_object) do |rel|
		    next unless rel.root_relation?

		    local_object.each_parent_object(rel) do |obj|
			return true if keep_object?(obj)
		    end
		    local_object.each_child_object(rel) do |obj|
			return true if keep_object?(obj)
		    end
		end

		if local_object.respond_to?(:each_plan_child)
		    local_object.each_plan_child do |child|
			return true if keep?(child)
		    end
		end

		false
	    end

	    # The list of objects that are being updated because of remote update
	    attr_reader :updated_objects

	    # True if we are updating +object+
	    def updating?(object)
		updated_objects.include?(object) 
	    end
	
	    # True if we are updating all objects in +objects+
	    def updating_all?(objects)
		updated_objects.include_all?(objects.to_value_set)
	    end

	    # Call the block with the objects in +objects+ added to the
	    # updated_objects set
	    def update_all(objects)
		old_updated_objects = @updated_objects
		@updated_objects |= objects.to_value_set
		yield
	    ensure
		@updated_objects = old_updated_objects
	    end

	    # Call the block with the objects in +objects+ added to the
	    # updated_objects set
	    def update(object)
		included = unless updated_objects.include?(object)
			       @updated_objects << object
			   end

		yield
	    ensure
		@updated_objects.delete(object) if included
	    end

	    # Allow objects of class +type+ to be accessed remotely using DRbObjects
	    def allow_remote_access(type)
		@allowed_remote_access << type
	    end
	    # Returns true if +object+ can be remotely represented by a DRbObject
	    # proxy
	    def allowed_remote_access?(object)
		@allowed_remote_access.any? { |type| object.kind_of?(type) }
	    end

	    def each_object_relation(object)
		object.each_relation do |rel|
		    yield(rel) if rel.distribute?
		end
	    end

	    # The list of known peers. See ConnectionSpace#peers
	    def peers
		if state then state.peers 
		else {}
		end
	    end
	end
    end
end
