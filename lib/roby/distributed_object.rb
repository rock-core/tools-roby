module Roby
    class ::Class
        # If true, this model will never get sent to remote peers.
        def private_model?
            if !@private_model.nil?
                @private_model
            else
                klass = superclass
                if superclass.respond_to?(:private_model?)
                    superclass.private_model?
                end
            end
        end

        # Declares that neither this model nor its subclasses should be sent to
        # remote peers.
        #
        # I.e., from the point of view of our peers, instances of this model are
        # actually instances of its superclass.
        def private_model; @private_model = true end
    end

    class ::Module
        # There are currently no way to make a module private
        def private_model?; false end
    end

    # Base class for most plan-related objects (Plan, PlanObject, ...)
    #
    # This class contains the information and manipulation attributes that are
    # at the core of Roby object management. In particular, it maintains the
    # distributed object information (needed in multi-Roby setups).
    class DistributedObject
        # The ID of the local process
        attr_reader :local_owner_id
	# The set of Peer objects which own this object
	attr_reader :owners

        attr_predicate :self_owned?
	
        def initialize # :nodoc:
            @owners = Array.new
            @self_owned = true
        end

	def initialize_copy(old) # :nodoc:
	    super
            @owners = Array.new
	end

        def add_owner(owner)
            @owners << owner
            @self_owned = @owners.include?(local_owner_id)
        end

        def remove_owner(owner)
            @owners.delete(owner)
            @self_owned = @owners.empty? || @owners.include?(local_owner_id)
        end

	# True if the given peer owns this object
        def owned_by?(peer_id)
            if peer_id == local_owner_id
                self_owned?
            else
                owners.include?(peer_id)
            end
        end

        def clear_owners
            owners.clear
            @self_owned = true
        end
    end
end

