module Roby
    module Interface
        # The server-side object allowing to access an interface (e.g. a Roby app)
        # through any communication channel
        class Server
            # @return [DRobyChannel] the IO to the client
            attr_reader :io
            # @return [Interface] the interface object we are giving access to
            attr_reader :interface

            # @param [DRobyChannel] io a channel to the server
            # @param [Interface] interface the interface object we give remote
            #   access to
            def initialize(io, interface)
                @io, @interface = io, interface
                interface.on_exception do |*args|
                    io.write_packet([:exception, *args])
                end
            end

            def to_io
                io.to_io
            end

            def handshake
                true
            end

            def close
                io.close
            end

            # Process one command from the client, and send the reply
            def poll
                m, *args = io.read_packet
                return if !m

                reply = if respond_to?(m)
                            send(m, *args)
                        else
                            interface.send(m, *args)
                        end

                io.write_packet([:reply, reply])
            rescue Exception => e
                io.write_packet([:bad_call, e])
            end
        end
    end
end

