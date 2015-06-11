module Roby
    module Distributed
        # A way to discover other dRoby instances through the use of a central
        # tuplespace
        class CentralDiscovery
            class AlreadyRegistered < RuntimeError; end

            # The tuplespace
            attr_reader :discovery_tuplespace
            # The tuple representing the local app
            attr_reader :tuple

            def initialize(discovery_tuplespace)
                @discovery_tuplespace = discovery_tuplespace
            end

            def registered?
                !!@tuple
            end

            def register(peer_id)
                if registered?
                    raise AlreadyRegistered, "there is already a tuple registered for localhost, call #deregister first"
                end

                @tuple = [:droby, name, remote_id]

                name, remote_id = neighbour.name, neighbour.remote_id

                discovery_tuplespace.write(tuple)
                if discovery_tuplespace.kind_of?(DRbObject)
                    Distributed.info "published #{name}(#{remote_id}) on #{discovery_tuplespace.__drburi}"
                else
                    Distributed.info "published #{name}(#{remote_id}) on local tuplespace"
                end
            end

            def deregister
                discovery_tuplespace.take(tuple)
            ensure
                @tuple = nil
            end

            def listening?
                true
            end

            def listen
            end

            def stop_listening
            end

            def neighbours
                discovery_tuplespace.read_all([:droby, nil, nil]).
                    map do |n| 
                        if n != tuple
                            Neighbour.new(n[1], n[2]) 
                        end
                    end.compact
            end
        end
    end
end

