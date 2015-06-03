module Roby
    module Interface
        # A wrapper on top of raw IO that uses droby marshalling to communicate
        class DRobyChannel
            # @return [#read_nonblock,#write] the channel that allows us to communicate to clients
            attr_reader :io
            # @return [Boolean] true if the local process is the client or the
            #   server
            attr_predicate :client?

            def initialize(io, client)
                @io = io
                @client = client

                @incoming =
                    if client?
                        WebSocket::Frame::Incoming::Client.new
                    else
                        WebSocket::Frame::Incoming::Server.new
                    end
            end

            def to_io
                io.to_io
            end

            def close
                io.close
            end

            def closed?
                io.closed?
            end

            def eof?
                io.eof?
            end

            # Read one packet from {#io} and unmarshal it
            #
            # It is non-blocking
            #
            # @return [Object,nil] returns the unmarshalled object, or nil if no
            #   full object can be found in the data received so far
            def read_packet
                data = begin io.read_nonblock(1024 ** 2)
                       rescue IO::WaitReadable
                       end
                if data
                    @incoming << data
                end

                if packet = @incoming.next
                    unmarshalled = begin Marshal.load(packet.to_s)
                                   rescue TypeError => e
                                       raise ProtocolError, "failed to unmarshal received packet: #{e.message}"
                                   end
                    Distributed::DumbManager.local_object(unmarshalled)
                end

            rescue Errno::ECONNRESET, EOFError
                raise ComError, "closed communication"
            rescue Errno::EPIPE
                raise ComError, "broken communication channel"
            end

            # Write one ruby object (usually an array) as a marshalled packet and
            # send it to {#io}
            #
            # @param [Object] object the object to be sent
            # @return [void]
            def write_packet(object)
                marshalled = Marshal.dump(object.droby_dump(nil))
                packet =
                    if client?
                        WebSocket::Frame::Outgoing::Client.new(data: marshalled, type: :binary)
                    else
                        WebSocket::Frame::Outgoing::Server.new(data: marshalled, type: :binary)
                    end

                io.write(packet.to_s)
                nil
            rescue Errno::EPIPE, IOError, Errno::ECONNRESET
                raise ComError, "broken communication channel"
            end
        end
    end
end

