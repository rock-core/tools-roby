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
    def referenced_objects
	@mutex.synchronize do
	    @values.keys
	end
    end
    def delete(object)
	@mutex.synchronize do
	    @values.delete(object)
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
	DISCOVERY_RING_PORT = 48901
	DEFAULT_DROBY_PORT  = 48902

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

	    def to_local(peer, create)
		object = local_object
		if object.kind_of?(RemoteID)
		    if local_proxy = peer.proxies[object]
			return peer.proxy_setup(local_proxy)
		    elsif !create
			return
		    elsif peer.removing_proxies.has_key?(object)
			marshalled_object = peer.removing_proxies[object].last
			Distributed.debug "reusing marshalled #{marshalled_object} for #{self} from #{peer}"
			marshalled_object.remote_siblings.delete(Distributed.droby_dump)
			marshalled_object.remote_siblings[peer.droby_dump] = self

			if marshalled_object.respond_to?(:plan) && !marshalled_object.plan
			    # Take care of the "proxy is GCed while the peer
			    # sends us messages about it" case. In this case,
			    # the object has already been removed when it is
			    # marshalled (#plan == nil).
			    #
			    # This cannot happen in transactions: it only happens
			    # in plans where one side can remove an object while
			    # the other side is doing something on it
			    marshalled_object.instance_variable_set(:@plan, Roby.plan)
			end

			object = peer.local_object(marshalled_object)

			if object.respond_to?(:plan) && !object.plan
			    raise "#{object} has no plan !"
			end

			return object
		    end
		    raise ArgumentError, "#{self} has no proxy"
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
	@keep = RefCounting.new
	@removed_objects = ValueSet.new
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
	    attr_reader :keep

	    def keep_object?(local_object)
	        !local_object.self_owned? && 
	            (local_object.subscribed? || 
	            Distributed.keep.ref?(local_object))
	    end

	    def remotely_useful_objects(candidates, result = nil)
		return ValueSet.new if candidates.empty?

		result  ||= Distributed.keep.referenced_objects.to_value_set

		child_set = ValueSet.new
	        for obj in candidates
	            if result.include?(obj.root_object)
			next
		    elsif obj.subscribed?
			result << obj
			next
		    end

		    not_found = obj.each_relation do |rel|
	        	next unless rel.distribute? && rel.root_relation?

	        	not_found = obj.each_parent_object(rel) do |parent|
	        	    parent = parent.root_object
	        	    if parent.distribute? && parent.self_owned?
	        		result << obj.root_object
	        		break
	        	    end
	        	end
	        	break unless not_found

	        	not_found = obj.each_child_object(rel) do |child|
	        	    child = child.root_object
	        	    if child.distribute? && child.self_owned?
	        		result << obj.root_object
	        		break
	        	    end
	        	end
	        	break unless not_found
	            end

		    if not_found && obj.respond_to?(:each_plan_child)
			obj.each_plan_child { |plan_child| child_set << plan_child }
		    end
	        end

		result.merge remotely_useful_objects(child_set, result)
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

	    # The set of objects that have been removed locally, but for which
	    # there are still references on our peers
	    attr_reader :removed_objects
	end

	@cycles_rx             = Queue.new
	@pending_cycles        = Array.new
	@pending_remote_events = Array.new

	class << self
	    # The queue of cycles read by ConnectionSpace#receive and not processed
	    attr_reader :cycles_rx
	    # The set of cycles that have been read from #pending_cycles but
	    # have not been processed yet because the peers have disabled_rx? set
	    #
	    # This variable must be accessed only in the control thread
	    attr_reader :pending_cycles
	end

	# Extract data received so far from our peers and replays it if
	# possible. Data can be ignored if RX is disabled with this peer
	# (through Peer#disable_rx), or delayed if there is event propagation
	# involved. In that last case, the events will be fired at the
	# beginning of the next execution cycle and the remaining messages at
	# the end of that same cycle.
	def self.process_pending
	    delayed_cycles = []
	    while !(pending_cycles.empty? && cycles_rx.empty?)
		peer, calls = if pending_cycles.empty?
				  cycles_rx.pop
			      else pending_cycles.shift
			      end

		if peer.disabled_rx?
		    delayed_cycles.push [peer, calls]
		else
		    if remaining = process_cycle(peer, calls)
			delayed_cycles.push [peer, remaining]
		    end
		end
	    end

	ensure
	    @pending_cycles = delayed_cycles
	end

	def self.process_cycle(peer, calls)
	    from = Time.now
	    calls_size = calls.size

	    peer_server = peer.local_server
	    peer_server.processing = true

	    if !peer.connected?
		return
	    end

	    while call_spec = calls.shift
		return unless call_spec

		is_callback, method, args, critical, message_id = *call_spec
		Distributed.debug do 
		    args_s = args.map { |obj| obj ? obj.to_s : 'nil' }
			"processing #{is_callback ? 'callback' : 'method'} [#{message_id}]#{method}(#{args_s.join(", ")})"
		end

		result = catch(:ignore_this_call) do
		    peer_server.queued_completion = false
		    peer_server.current_message_id = message_id
		    peer_server.processing_callback = !!is_callback

		    result = begin
				 peer_server.send(method, *args)
			     rescue Exception => e
				 if critical
				     Roby::Distributed.fatal "fatal error during #{method}(#{args}): #{e}"
				     Roby::Distributed.debug do
					 e.full_message
				     end
				     peer.fatal_error e, method, args
				 else
				     peer_server.completed!(e, true)
				 end
			     end

		    if !peer.connected?
			return
		    end
		    result
		end

		if method != :completed && method != :completion_group && !peer.disconnecting? && !peer.disconnected?
		    if peer_server.queued_completion?
			Distributed.debug "done and already queued the completion message"
		    else
			Distributed.debug { "done, returns #{result || 'nil'}" }
			peer.queue_call false, :completed, [result, false, message_id]
		    end
		end

		if peer.disabled_rx?
		    return calls
		end

	    end

	    Distributed.debug "successfully served #{calls_size} calls in #{Time.now - from} seconds"
	    nil

	rescue Exception => e
	    Distributed.info "error in dRoby processing: #{e.full_message}"
	    peer.disconnect

	ensure
	    peer_server.processing = false
	end
    end
end
