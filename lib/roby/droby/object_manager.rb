module Roby
    module DRoby
        # The object manager manages the IDs of an object among known peers
        class ObjectManager
            # The Peer ID of the local Roby instance
            #
            # @return [PeerID]
            attr_reader :local_id

            # Resolution of a remote DRobyID by first the object's local ID and
            # then the remote PeerID
            attr_reader :siblings_by_local_object_id

            # Mapping of known objects by peer and droby ID
            attr_reader :siblings_by_peer

            # Resolution of models by name
            attr_reader :models_by_name

            def initialize(local_id)
                @local_id = local_id
                clear
            end

            def clear
                @siblings_by_peer = Hash.new { |h, k| h[k] = Hash.new }
                @siblings_by_local_object_id = Hash.new { |h, k| h[k] = Hash.new }
                @models_by_name = Hash.new
            end

            def find_by_id(peer_id, droby_id)
                if object_siblings = siblings_by_peer.fetch(peer_id, nil)
                    object_siblings[droby_id]
                end
            end

            def fetch_by_id(peer_id, droby_id)
                if local_object = find_by_id(peer_id, droby_id)
                    local_object
                else
                    raise UnknownSibling, "there is no known object for #{droby_id}@#{peer_id}"
                end
            end

            def known_sibling_on(local_object, peer_id)
                known_siblings_for(local_object)[peer_id]
            end

            def known_siblings_for(object)
                if object.respond_to?(:droby_id) && (siblings = siblings_by_local_object_id.fetch(object.droby_id, nil))
                    siblings
                else Hash.new
                end
            end

            # Tests whether self knows about a local object
            def include?(local_object)
                siblings_by_local_object_id.has_key?(local_object.droby_id)
            end

            # Registers siblings for a local object
            #
            # Unlike {#register_object}, it does not automatically adds the
            # local mapping to the set of known siblings
            def register_siblings(local_object, siblings)
                local_object_id = local_object.droby_id
                siblings.each do |peer_id, droby_id|
                    siblings_by_peer[peer_id][droby_id] = local_object
                end
                siblings_by_local_object_id[local_object_id].
                    merge!(siblings)
            end

            # Deregisters siblings of a known local object
            #
            # If the object has no known siblings left, it is also
            # deregistered
            def deregister_siblings(local_object, siblings)
                local_object_id = local_object.droby_id
                object_siblings = siblings_by_local_object_id[local_object_id]

                siblings.each do |peer_id, droby_id|
                    if actual_droby_id = object_siblings.delete(peer_id)
                        if actual_droby_id != droby_id
                            raise ArgumentError, "DRobyID of #{local_object} on #{peer_id} mismatches between provided #{droby_id} and registered #{actual_droby_id}"
                        end
                        siblings_by_peer[peer_id].delete(droby_id)
                    end
                end
                if object_siblings.empty?
                    deregister_object(local_object)
                end
            end

            # Registers a local object in this manager, along with known
            # siblings
            def register_object(local_object, known_siblings = Hash.new)
                register_siblings(local_object, local_id => local_object.droby_id)
                register_siblings(local_object, known_siblings)
            end

            # Deregisters an object from this manager
            def deregister_object(local_object)
                siblings = siblings_by_local_object_id.delete(local_object.droby_id)
                siblings.each do |peer_id, droby_id|
                    siblings_by_peer[peer_id].delete(droby_id)
                end

                if local_object.respond_to?(:name)
                    if local_object == models_by_name[n = local_object.name]
                        models_by_name.delete(n)
                    end
                end
            end

            # Register a model and a list of known siblings for it
            #
            # In addition to ID-based resolution, models can also be
            # resolved by name
            def register_model(local_object, known_siblings = Hash.new)
                if n = local_object.name
                    models_by_name[n] = local_object
                end
                register_object(local_object, known_siblings)
            end

            def find_model_by_name(name)
                models_by_name[name]
            end
        end
    end
end

