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
	# The set of Peer objects which own this object
	attr_reader :owners
	
        def initialize # :nodoc:
            @owners = Array.new
        end

	def initialize_copy(old) # :nodoc:
	    super
            @owners = Array.new
	end

	# True if we own this object
        def self_owned?
            owners.empty? || owners.include?(local_owner_id)
        end

	# True if the given peer owns this object
        def owned_by?(peer_id)
            owners.include?(peer_id)
        end
    end
end

