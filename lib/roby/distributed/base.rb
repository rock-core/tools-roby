module Roby
    module Distributed
	class InvalidRemoteOperation < RuntimeError; end
	class RemotePeerMismatch     < RuntimeError; end

	class InvalidRemoteTaskOperation < InvalidRemoteOperation
	    attr_reader :task
	    def initialize(task); @task = task end
	end

	extend Logger::Hierarchy
	extend Logger::Forward

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

	    def remotely_useful?(local_object)
		return true if local_object.remotely_useful?
		Roby::Distributed.each_object_relation(local_object) do |rel|
		    return true if local_object.related_objects(rel).any? { |obj| obj.remotely_useful? }
		end

		if local_object.respond_to?(:each_plan_child)
		    local_object.each_plan_child do |child|
			return true if remotely_useful?(child)
		    end
		end

		false
	    end

	    # The list of objects that are being updated because of remote update
	    attr_reader :updated_objects

	    # If we are updating all objects in +objects+
	    def updating?(objects)
		updated_objects.include_all?(objects) 
	    end

	    # Call the block with the objects in +objects+ added to the
	    # updated_objects set
	    def update(objects)
		old_updated = updated_objects
		@updated_objects |= objects

		yield

	    ensure
		@updated_objects = old_updated
	    end

	    # Allow objects of class +type+ to be accessed remotely using
	    # DRbObjects
	    def allow_remote_access(type)
		@allowed_remote_access << type
	    end
	    # Returns true if +object+ can be remotely represented by a DRbObject
	    # proxy
	    def allowed_remote_access?(object)
		@allowed_remote_access.any? { |type| object.kind_of?(type) }
	    end

	    def each_object_relation(object)
		if object.respond_to?(:each_discovered_relation)
		    object.each_discovered_relation do |rel|
			yield(rel) if rel.distribute?
		    end
		else
		    object.each_relation do |rel|
			yield(rel) if rel.distribute?
		    end
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

