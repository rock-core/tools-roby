module Roby
    module Distributed
	class InvalidRemoteOperation < RuntimeError; end

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

	    def keep?(local_object)
		return true if local_object.remotely_useful? ||
		    local_object.subscribed?

		Roby::Distributed.each_object_relation(local_object) do |rel|
		    local_object.each_parent_object(rel) do |obj|
			return true if obj.remotely_useful? || obj.subscribed?
		    end
		    local_object.each_child_object(rel) do |obj|
			return true if obj.remotely_useful? || obj.subscribed?
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
		@updated_objects << object
		yield
	    ensure
		@updated_objects.delete(object)
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

