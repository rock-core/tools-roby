require 'drb'

# A thread-safe reference-counting class
class RefCounting
    def initialize
	@values = Hash.new(0)
	@mutex  = Mutex.new
    end

    # True if +obj+ is referenced
    def ref?(obj); @mutex.synchronize { @values[obj] > 0 } end
    # Dereference +obj+ by one
    def deref(obj)
	@mutex.synchronize do
	    if (@values[obj] -= 1) == 0
		@values.delete(obj)
		return true
	    end
	end
	false
    end
    # Add +1 to the reference count of +obj+
    def ref(obj)
	@mutex.synchronize do
	    @values[obj] += 1
	end
    end
    # Returns the set of referenced objects
    def referenced_objects
	@mutex.synchronize do
	    @values.keys
	end
    end
    # Remove +object+ from the set of referenced objects, regardless of its
    # reference count
    def delete(object)
	@mutex.synchronize do
	    @values.delete(object)
	end
    end
end

class Object
    def initialize_copy(old) # :nodoc:
	super
	@__droby_remote_id__ = nil
    end

    # The Roby::Distributed::RemoteID for this object
    def remote_id
	@__droby_remote_id__ ||= Roby::Distributed::RemoteID.from_object(self)
    end
end

class DRbObject
    # We don't want this method to call the remote object.
    def to_s
        "#<DRbObject>"
    end

    # Converts this DRbObject into Roby::Distributed::RemoteID
    def remote_id
	@__droby_remote_id__ ||= Roby::Distributed::RemoteID.new(__drburi, __drbref)
    end
end

module Roby
    module Distributed
	DEFAULT_DROBY_PORT  = 48900
        DEFAULT_RING_PORT   = 48901
        DEFAULT_TUPLESPACE_PORT = 48901

	extend Logger::Hierarchy
	extend Logger::Forward

	@updated_objects = Set.new
	@keep = RefCounting.new
	@removed_objects = Set.new
	class << self
            # The one and only ConnectionSpace object
	    attr_reader :state

            # Sets the #state attribute for Roby::Distributed
	    def state=(new_state)
		if log = logger
		    if new_state
			logger.progname = new_state.name
		    else
			logger.progname = "Roby"
		    end
		end

                if !Roby.plan
                    Roby.instance_variable_set :@plan, new_state.plan
                    Roby.instance_variable_set :@engine, new_state.plan.engine
                elsif new_state && Roby.plan != new_state.plan
                    raise ArgumentError, "plan mismatch between Roby.plan(#{plan}) and new_state.plan(#{new_state.plan}). Cannot set Distributed.state"
                end

		@state = new_state
	    end

            # True if this plan manager owns +object+
	    def owns?(object); !state || state.owns?(object) end

	    # The set of objects we should temporarily keep because they are used
	    # in a callback mechanism (like a remote query or a trigger)
	    attr_reader :keep

            # Compute the subset of +candidates+ that are to be considered as
            # useful because of our peers and returns it.
            #
            # More specifically, an object will be included in the result if:
            # * this plan manager is subscribed to it
            # * the object is directly related to a self-owned object
            # * if +include_subscriptions_relations+ is true, +object+ is
            #   directly related to a subscribed object.
            #
            # The method takes into account plan children in its computation:
            # for instance, a task will be included in the result if one of
            # its events meet the requirements described above.
            #
            # If +result+ is non-nil, the method adds the objects to +result+
            # using #<< and returns it.
	    def remotely_useful_objects(candidates, include_subscriptions_relations, result = nil)
		return Set.new if candidates.empty?

		result  ||= Distributed.keep.referenced_objects.to_set

		child_set = Set.new
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
	        	    if parent.distribute? && 
				((include_subscriptions_relations && parent.subscribed?) || parent.self_owned?)
	        		result << obj.root_object
	        		break
	        	    end
	        	end
	        	break unless not_found

	        	not_found = obj.each_child_object(rel) do |child|
	        	    child = child.root_object
	        	    if child.distribute? && 
				((include_subscriptions_relations && child.subscribed?) || child.self_owned?)
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

		result.merge remotely_useful_objects(child_set, false, result)
	    end

	    # The list of objects that are being updated because of remote update
	    attr_reader :updated_objects

	    # True if we are updating +object+
	    def updating?(object)
		@update_all || updated_objects.include?(object) 
	    end
	
	    # True if we are updating all objects in +objects+
	    def updating_all?(objects)
		@update_all || updated_objects.superset?(objects)
	    end

	    # Call the block with the objects in +objects+ added to the
	    # updated_objects set
	    def update_all(objects)
		old_updated_objects = @updated_objects
		@updated_objects |= objects.to_set
		yield
	    ensure
		@updated_objects = old_updated_objects
	    end

            def disable_ownership
                if !block_given?
                    @update_all = true
                    return
                end

                begin
                    current, @update_all = @update_all, true
                    yield
                ensure
                    @update_all = current
                end
            end

            def enable_ownership
                @update_all = false
            end

	    # Call the block with the objects in +objects+ added to the
	    # updated_objects set
	    def update(object)
		if object.respond_to?(:__getobj__) && !object.kind_of?(Roby::Transaction::Proxying)
		    object = object.__getobj__
		end

		included = unless updated_objects.include?(object)
			       @updated_objects << object
			   end

		yield
	    ensure
		@updated_objects.delete(object) if included
	    end

            # Yields the relations of +object+ which are to be distributed
            # among peers.
	    def each_object_relation(object)
		object.each_relation do |rel|
		    yield(rel) if rel.distribute?
		end
	    end

	    # The list of known peers. See ConnectionSpace#peers
	    def peers
		if state then state.peers 
		else (@peers ||= Hash.new)
		end
	    end

	    # The set of objects that have been removed locally, but for which
	    # there are still references on our peers
	    attr_reader :removed_objects

            def remote_name; "local" end
	end

        # Replaying logged data is a bit tricky, as the local ID manager will
        # think that we are unmarshalling stuff that we marshalled ...
        #
        # The proper solution is a big refactoring of the object management.
        # Unfortunately, it is not that high on the TODO list. For now, create
        # unique remote_id and droby_dump values to make the local process look
        # different from a normal Roby process
        def self.setup_log_replay(object_manager)
            @__single_remote_id__ = RemoteID.new('log_replay', 1)
            @__single_marshalled_peer__ = Peer::DRoby.new('single', remote_id)
            peers[RemoteID.new('local', 0)] = object_manager
        end

        # Returns a RemoteID object suitable to represent this plan manager on
        # the network.
        #
        # This makes Roby::Distributed behave like a Peer object
	def self.remote_id
	    if state then state.remote_id
	    else @__single_remote_id__ ||= RemoteID.new('local', 0)
	    end
	end

        # Returns a Peer::DRoby object which can be used in the dRoby
        # connection to represent this plan manager.
        #
        # This makes Roby::Distributed behave like a Peer object
	def self.droby_dump(dest = nil)
	    if state then state.droby_dump(dest)
	    else @__single_marshalled_peer__ ||= Peer::DRoby.new('single', remote_id)
	    end
	end
    end
end

