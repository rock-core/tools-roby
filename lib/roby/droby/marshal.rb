module Roby
    module DRoby
        # Handles marshalling and demarshalling objects for a given peer
        class Marshal
            # The object that allows to match objects known locally with the
            # objects transmitted by the peer
            attr_reader :object_manager

            # @api private
            #
            # Objects that are temporarily referenced by IDs
            #
            # This is used by {#dump_groups} and {#load_groups}
            attr_reader :context_objects

            # The ID of the peer that self handles
            #
            # @return [PeerID]
            attr_reader :peer_id

            # Whether {#local_plan} should just create a plan object if an ID
            # cannot be resolved
            #
            # Use this when the purpose of marshalling/demarshalling is to use
            # Roby objects as information holders, without caring about the
            # plan structure itself
            attr_predicate :auto_create_plans?

            def initialize(object_manager = ObjectManager.new(nil), peer_id = nil, auto_create_plans: false)
                @object_manager = object_manager
                @peer_id = peer_id
                @context_objects = Hash.new
                @auto_create_plans = auto_create_plans
            end


            def with_object(id_to_object)
                current_context = context_objects.dup
                id_to_object.each do |id, object|
                    context_objects[id] = object
                    context_objects[RemoteDRobyID.new(peer_id, id)] = object
                end

                yield

            ensure
                context_objects.replace(current_context)
            end

            # Temporarily register sets of objects
            #
            # Use this method to marshal sets of objects that could be
            # referencing each other. Using this method ensures that the
            # cross-references are marshalled using IDs instead of full objects
            def dump_groups(*groups)
                current_context = context_objects.dup
                mappings = groups.map do |collection|
                    mapping = Array.new
                    collection.each do |obj|
                        context_objects[obj] = obj.droby_id
                        mapping << [obj.droby_id, obj]
                    end
                    mapping
                end

                marshalled = mappings.map do |collection|
                    collection.flat_map do |obj_id, obj|
                        [obj_id, obj.droby_dump(self)]
                    end
                end

                if block_given?
                    yield(*marshalled)
                else return *marshalled
                end

            ensure
                context_objects.replace(current_context)
            end

            # Load groups marshalled with {#dump_groups}
            def load_groups(*groups)
                current_context = context_objects.dup

                updates = Array.new
                local_objects = groups.map do |collection|
                    collection.each_slice(2).map do |obj_id, marshalled_obj|
                        proxy = local_object(marshalled_obj)
                        context_objects[obj_id] = proxy

                        if marshalled_obj.respond_to?(:remote_siblings)
                            object_manager.register_object(proxy, marshalled_obj.remote_siblings)
                        end
                        if marshalled_obj.respond_to?(:update)
                            updates << [marshalled_obj, proxy]
                        end
                        proxy
                    end
                end

                updates.each do |marshalled, local|
                    marshalled.update(self, local, fresh_proxy: true)
                end

                if block_given?
                    yield(*local_objects)
                else return *local_objects
                end
            ensure
                context_objects.replace(current_context)
            end

            # Dump an object for transmition to the peer
            def dump(object)
                if droby_id = context_objects[object]
                    droby_id
                elsif object.respond_to?(:droby_dump)
                    if sibling = object_manager.registered_sibling_on(object, peer_id)
                        RemoteDRobyID.new(peer_id, sibling)
                    else
                        object.droby_dump(self)
                    end
                else
                    object
                end
            end

            def dump_model(object)
                marshalled = dump(object)
                if !marshalled.kind_of?(RemoteDRobyID) && object.respond_to?(:droby_dump)
                    register_model(object)
                end
                marshalled
            end

            # Finds a local object that matches the object transmitted by
            # our peer
            #
            # @return [(Boolean,Object)] whether the object was resolved and the
            #   unmarshalled object
            def find_local_object(marshalled)
                if local_object = context_objects[marshalled]
                    return true, local_object
                elsif marshalled.kind_of?(DRobyID)
                    return true, object_manager.fetch_by_id(peer_id, marshalled)
                elsif marshalled.kind_of?(RemoteDRobyID)
                    return true, object_manager.fetch_by_id(marshalled.peer_id, marshalled.droby_id)
                elsif marshalled.respond_to?(:remote_siblings)
                    marshalled.remote_siblings.each do |peer_id, droby_id|
                        if local_object = object_manager.find_by_id(peer_id, droby_id)
                            # In case the remote siblings got updated since
                            # last time
                            object_manager.register_siblings(local_object, marshalled.remote_siblings)
                            if marshalled.respond_to?(:update)
                                marshalled.update(self, local_object)
                            end
                            return true, local_object
                        end
                    end
                    return false, nil
                elsif !marshalled.respond_to?(:proxy)
                    return true, marshalled
                else
                    return false, nil
                end
            end

            # Resolves a marshalled object into a local object
            #
            # Unlike {#find_local_object}, it raises if the object cannot be
            # resolved
            def local_object(marshalled, create: true)
                resolved, local_object = find_local_object(marshalled)
                if resolved 
                    local_object
                elsif marshalled.respond_to?(:remote_siblings)
                    if !create
                        raise NoLocalObject, "#{marshalled} cannot be resolved into a local object and create is false"
                    end

                    local_object = marshalled.proxy(self)
                    if local_object.respond_to?(:droby_id)
                        object_manager.register_object(local_object, marshalled.remote_siblings)
                    end
                    if marshalled.respond_to?(:update)
                        marshalled.update(self, local_object, fresh_proxy: true)
                    end
                    local_object
                elsif marshalled.respond_to?(:proxy)
                    marshalled.proxy(self)
                else
                    raise NoLocalObject, "#{marshalled} cannot be resolved into a local object"
                end
            end

            # Resolve an ID that is known to represent a plan
            #
            # It calls {#local_object} by default, but can be overriden for e.g.
            # environments where rebuilding a plan structure is not important
            # (e.g. the shell)
            def local_plan(marshalled)
                local_object(marshalled)
            rescue UnknownSibling
                Plan.new
            end

            # Find a known model matching the given name
            #
            # It is first resolved among the 
            # models registered with {#register_model} and then resolved in
            # the process constant hierarchy
            def find_local_model(marshalled, name: marshalled.name)
                resolved, local_model = find_local_object(marshalled)
                if resolved
                    return local_model
                elsif name && (local_model = object_manager.find_model_by_name(name))
                    return local_model
                elsif !marshalled.name
                    return
                end

                names = marshalled.name.split('::')

                # Look locally for the constant listed in the name
                local_object = Object
                while subname = names.shift
                    if subname =~ /^[A-Z]\w*$/ && local_object.const_defined_here?(subname)
                        local_object = local_object.const_get(subname)
                    else return
                    end
                end
                return local_object
            end

            def local_model(marshalled, create: true)
                model = local_object(marshalled, create: create)
                object_manager.register_model(model)
                model
            end

            # (see ObjectManager#find_model_by_name)
            def find_model_by_name(name)
                object_manager.find_model_by_name(name)
            end

            # (see ObjectManager#register_object)
            def register_object(object, known_siblings = Hash.new)
                object_manager.register_object(object, known_siblings)
            end

            # (see ObjectManager#register_model)
            def register_model(local_model, known_siblings = Hash.new, name: local_model.name)
                object_manager.register_model(local_model, known_siblings, name: name)
            end

            # (see ObjectManager#known_siblings_for)
            def known_siblings_for(object)
                object_manager.known_siblings_for(object)
            end
        end
    end
end


