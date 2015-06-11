module Roby
    module Distributed

    # This object manages the RemoteID sent by the remote peers, making sure
    # that there is at most one proxy task locally for each ID received
    class RemoteObjectManager
        # The main plan managed by this plan manager. Main plans are mapped to
        # one another across dRoby connections
        attr_reader :plan
	# The set of proxies for object from this remote peer
	attr_reader :proxies
	# The set of proxies we are currently removing. See BasicObject#forget_peer
	attr_reader :removing_proxies
        # This method is used by Distributed.format to determine the dumping
        # policy for +object+. If the method returns true, then only the
        # RemoteID object of +object+ will be sent to the peer. Otherwise,
        # an intermediate object describing +object+ is sent.
	def incremental_dump?(object)
	    object.respond_to?(:remote_siblings) && object.remote_siblings[self] 
	end

        # If true, the manager will use the remote_siblings hash in the
        # marshalled data to determine which proxy #local_object should return.
        #
        # If false, it won't
        #
        # It is true by default. Only logging needs to disable it as the logger
        # is not a dRoby peer
        attr_predicate :use_local_sibling?, true

        def initialize(plan)
            @plan = plan
	    @proxies	  = Hash.new
	    @removing_proxies = Hash.new { |h, k| h[k] = Array.new }
            @use_local_sibling = true
        end

	# Returns the remote object for +object+. +object+ can be either a
	# DRbObject, a marshalled object or a local proxy. In the latter case,
	# a RemotePeerMismatch exception is raised if the local proxy is not
	# known to this peer.
	def remote_object(object)
	    if object.kind_of?(RemoteID)
		object
	    else object.sibling_on(self)
	    end
	end
	
	# Returns the remote_object, local_object pair for +object+. +object+
	# can be either a marshalled object or a local proxy. Raises
	# ArgumentError if it is none of the two. In the latter case, a
	# RemotePeerMismatch exception is raised if the local proxy is not
	# known to this peer.
	def objects(object, create_local = true)
	    if object.kind_of?(RemoteID)
		if local_proxy = proxies[object]
		    proxy_setup(local_proxy)
		    return [object, local_proxy]
		end
		raise ArgumentError, "got a RemoteID which has no proxy"
	    elsif object.respond_to?(:proxy)
		[object.remote_object, local_object(object, create_local)]
	    else
		[object.sibling_on(self), object]
	    end
	end

	def proxy_setup(local_object)
	    local_object
	end

	# Returns the local object for +object+. +object+ can be either a
	# marshalled object or a local proxy. Raises ArgumentError if it is
	# none of the two. In the latter case, a RemotePeerMismatch exception
	# is raised if the local proxy is not known to this peer.
	def local_object(marshalled, create = true)
	    if marshalled.kind_of?(RemoteID)
		return marshalled.to_local(self, create)
	    elsif !marshalled.respond_to?(:proxy)
		return marshalled
	    elsif marshalled.respond_to?(:remote_siblings)
		# 1/ try any local RemoteID reference registered in the marshalled object
		local_id  = marshalled.remote_siblings[Roby::Distributed.droby_dump]
		if use_local_sibling? && local_id
		    local_object = local_id.local_object rescue nil
		    local_object = nil if local_object.finalized?
		end

		# 2/ try the #proxies hash
		if !local_object 
                    marshalled.remote_siblings.each_value do |remote_id|
                        if local_object = proxies[remote_id]
                            break
                        end
                    end

                    if !local_object
			if !create
                            return
                        end

			# remove any local ID since we are re-creating it
                        if use_local_sibling?
                            marshalled.remote_siblings.delete(Roby::Distributed.droby_dump)
                        end
			local_object = marshalled.proxy(self)

                        # NOTE: the proxies[] hash is updated by the BasicObject
                        # and BasicObject::DRoby classes, mostly in #update()
                        #
                        # This is so as we have to distinguish between "register
                        # proxy locally" (#add_sibling_for) and "register proxy
                        # locally and announce it to our peer" (#sibling_of)
		    end
		end

		if !local_object
		    raise "no remote siblings for #{remote_name} in #{marshalled} (#{marshalled.remote_siblings})"
		end

		if marshalled.respond_to?(:update)
		    Roby::Distributed.update(local_object) do
			marshalled.update(self, local_object) 
		    end
		end
		proxy_setup(local_object)
	    else
		local_object = marshalled.proxy(self)
	    end

	    local_object
	end
	alias proxy local_object

        # Copies the state of this object manager, using +mappings+ to convert
        # the local objects
        #
        # If mappings is not given, an identity is used
        def copy_to(other_manager, mappings = nil)
            mappings ||= Hash.new { |h, k| k }
            proxies.each do |sibling, local_object|
                if mappings.has_key?(local_object)
                    other_manager.proxies[sibling] = mappings[local_object]
                end
            end
        end

        # Returns a new local model named +name+ created by this remote object
        # manager
        #
        # This is used to customize the anonymous model building process based
        # on the RemoteObjectManager instance that is being provided
        def local_model(parent_model, name)
            Roby::Distributed::DRobyModel.anon_model_factory(parent_model, name)
        end

        # Returns a new local task tag named +name+ created by this remote
        # object manager
        #
        # This is used to customize the anonymous task tag building process
        # based on the RemoteObjectManager instance that is being provided
        def local_task_tag(name)
            Roby::Models::TaskServiceModel::DRoby.anon_tag_factory(name)
        end

        # Called when +remote_object+ is a sibling that should be "forgotten"
        #
        # It is usually called by Roby::BasicObject#remove_sibling_for
        def removed_sibling(remote_object)
            if remote_object.respond_to?(:remote_siblings)
                remote_object.remote_siblings.each_value do |remote_id|
                    proxies.delete(remote_id)
                end
            else
                proxies.delete(remote_object)
            end
        end

        def clear
            proxies.each_value do |obj|
                obj.remote_siblings.delete(self)
            end
            proxies.clear
            removing_proxies.clear
        end
    end

    end
end
