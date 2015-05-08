module Roby
    module Distributed
        # Discovery of dRoby instances through {Rinda::RingFinger}
        class RingDiscovery
            class AlreadyRegistered < RuntimeError; end

            # The port on which the tuplespaces should announce themselves
            attr_reader :port
            # The discovery timeout (in seconds)
            attr_reader :timeout

            # The {Rinda::RingFinger} instance that allows to enumerate the
            # dRoby instances
            #
            # Non-nil only if {#listen} has been called
            attr_reader :finger
            # The {Rinda::RingServer} instance that allows to publish the local
            # Roby instance
            #
            # Non-nil only if {#register} has been called
            attr_reader :server
            # The tuple as published
            #
            # Non-nil only if {#register} has been called
            attr_reader :tuple

            def initialize(port: DEFAULT_RING_PORT, timeout: 2)
                @port = port
                @timeout = timeout
            end

            def registered?
                !!@server
            end

            def register(peer_id, **options)
                if registered?
                    raise AlreadyRegistered, "already register the local connection space, call #deregister first"
                end
                @tuplespace = Rinda::TupleSpace.new
                @tuplespace.write([:droby, peer_id.name, peer_id.remote_id])
                @server = Rinda::RingServer.new(@tuplespace, [Socket::INADDR_ANY], port)
            end

            def deregister
                @server.shutdown
                @server = nil
            end

            def listening?
                !!@finger
            end

            def listen(broadcast_address)
                if listening?
                    raise AlreadyRegistered, "already listening"
                end
                @finger = Rinda::RingFinger.new([broadcast_address], port)
            end

            def stop_listening
                @finger = nil
            end

            def neighbours
                result = Array.new
                finger.lookup_ring(timeout) do |remote_tuplespace|
                    next if remote_tuplespace == @tuplespace
                    remote_tuplespace.read_all([:droby, nil, nil]).
                        each do |n| 
                            result << Neighbour.new(n[1], n[2]) 
                        end
                end
                result
            end
        end
    end
end

