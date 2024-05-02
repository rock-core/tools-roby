# frozen_string_literal: true

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
                @siblings_by_peer = Hash.new { |h, k| h[k] = {} }
                @siblings_by_local_object_id = Hash.new { |h, k| h[k] = {} }
                @models_by_name = {}
            end

            def find_by_id(peer_id, droby_id)
                if (object_siblings = siblings_by_peer.fetch(peer_id, nil))
                    object_siblings[droby_id]
                end
            end

            def fetch_by_id(peer_id, droby_id)
                if (local_object = find_by_id(peer_id, droby_id))
                    local_object
                else
                    raise UnknownSibling, "there is no known object for #{droby_id}@#{peer_id.inspect} on #{self}"
                end
            end

            # The registered ID for this object on a given peer
            #
            # @param [#droby_id] local_object
            # @param [PeerID] peer_id the ID of our peer
            # @return [DRobyID,nil]
            def registered_sibling_on(local_object, peer_id)
                return unless local_object.respond_to?(:droby_id)

                siblings =
                    siblings_by_local_object_id.fetch(local_object.droby_id, nil)
                siblings[peer_id] if siblings
            end

            # The ID this object is known for on the given peer
            #
            # @param [#droby_id] local_object
            # @param [PeerID] peer_id the ID of our peer
            # @return [DRobyID,nil]
            def known_sibling_on(local_object, peer_id)
                if local_object.respond_to?(:droby_id)
                    if (siblings = siblings_by_local_object_id.fetch(local_object.droby_id, nil))
                        siblings[peer_id]
                    elsif peer_id == local_id
                        local_object.droby_id
                    end
                end
            end

            # The set of IDs known for this object
            #
            # This returns a mapping from peer IDs to the ID of the provided
            # object on this peer. The list of siblings is maintained by
            # {#register_object} and {#deregister_object}
            #
            # @param [Object] object
            # @return [Hash] the siblings. A hash that announces the local ID is
            #   returned if the object is not registered, and an empty hash if
            #   it is not DRoby-addressable
            def known_siblings_for(object)
                if object.respond_to?(:droby_id)
                    if (siblings = siblings_by_local_object_id.fetch(object.droby_id, nil))
                        siblings
                    else
                        { local_id => object.droby_id }
                    end
                else
                    {}
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
                siblings_by_local_object_id[local_object_id]
                    .merge!(siblings)
            end

            # Deregisters siblings of a known local object
            #
            # If the object has no known siblings left, it is also
            # deregistered
            def deregister_siblings(local_object, siblings)
                local_object_id = local_object.droby_id
                object_siblings = siblings_by_local_object_id[local_object_id]

                siblings.each do |peer_id, droby_id|
                    if (actual_droby_id = object_siblings.delete(peer_id))
                        if actual_droby_id != droby_id
                            raise ArgumentError,
                                  "DRobyID of #{local_object} on #{peer_id} mismatches " \
                                  "between provided #{droby_id} and registered " \
                                  "#{actual_droby_id}"
                        end

                        siblings_by_peer[peer_id].delete(droby_id)
                    end
                end
                if object_siblings.empty?
                    deregister_object(local_object)
                end
            end

            # Registers the mappings from object IDs to the corresponding local object
            #
            # This registers the mapping for the local process (local_id =>
            # local_object.droby_id), along with known siblings if provided
            def register_object(local_object, known_siblings = {})
                register_siblings(local_object, local_id => local_object.droby_id)
                register_siblings(local_object, known_siblings)
            end

            # Deregisters a mapping from object IDs to a particular object
            def deregister_object(local_object)
                siblings = siblings_by_local_object_id.delete(local_object.droby_id)
                siblings.each do |peer_id, droby_id|
                    siblings_by_peer[peer_id].delete(droby_id)
                end

                if local_object.respond_to?(:name)
                    n = local_object.name
                    models_by_name.delete(n) if local_object == models_by_name[n]
                end
            end

            # Register a model by name and a list of known siblings for it
            #
            # In addition to ID-based resolution, models can also be resolved by
            # name through {#find_model_by_name}. This registers the name
            # mapping and then calls {#register_object}
            def register_model(local_object, known_siblings = {}, name: local_object.name)
                models_by_name[name] = local_object if name
                register_object(local_object, known_siblings)
            end

            # Attempts to resolve a registered model by its name
            #
            # In addition to ID-based resolution, models registered with
            # {#register_model} can also be resolved by name.
            #
            # This attempts a name-based resolution
            #
            # @param [String] name the name of the model to resolve
            # @return [Object,nil]
            def find_model_by_name(name)
                models_by_name[name]
            end

            def pretty_print(pp)
                pp.text "Object manager with local ID=#{local_id}"
                pp.nest(2) do
                    pp.breakable
                    pp.text "Registered objects"
                    siblings_by_peer.each do |peer_id, siblings|
                        siblings.each do |peer_object_id, object|
                            pp.breakable
                            pp.text "  #{peer_object_id}@#{peer_id} "
                            pp.nest(4) do
                                object.pretty_print(pp)
                            end
                        end
                    end
                end
            end

            def stat
                { siblings_by_local_object_id: siblings_by_local_object_id.size,
                  models_by_name: models_by_name.size,
                  siblings_by_peer: siblings_by_peer.inject(0) { |sum, (_, siblings)| sum + siblings.size } }
            end
        end
    end
end
