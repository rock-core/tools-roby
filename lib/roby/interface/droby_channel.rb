module Roby
    module Interface
        # A wrapper on top of raw IO that uses droby marshalling to communicate
        class DRobyChannel
            # @return [#read_nonblock,#write] the channel that allows us to communicate to clients
            attr_reader :io
            # @return [Boolean] true if the local process is the client or the
            #   server
            attr_predicate :client?
            # @return [Distributed::RemoteObjectManager] a manager object used
            #   to demarshal objects to/from the connection
            attr_reader :remote_object_manager

            def initialize(io, client, remote_object_manager: Distributed::DumbManager)
                @io = io
                @client = client

                @incoming =
                    if client?
                        WebSocket::Frame::Incoming::Client.new
                    else
                        WebSocket::Frame::Incoming::Server.new
                    end
                @remote_object_manager = remote_object_manager
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

            def flush
                io.flush
            end

            # Read one packet from {#io} and unmarshal it
            #
            # @return [Object,nil] returns the unmarshalled object, or nil if no
            #   full object can be found in the data received so far
            def read_packet(timeout = 0)
                start = Time.now

                begin
                    if data = io.read_nonblock(1024 ** 2)
                        @incoming << data
                    end
                rescue IO::WaitReadable
                end

                while !(packet = @incoming.next)
                    if timeout
                        remaining_time = timeout - (Time.now - start)
                        return if remaining_time < 0
                    end

                    if IO.select([io], [], [], remaining_time)
                        begin
                           if data = io.read_nonblock(1024 ** 2)
                               @incoming << data
                           end
                        rescue IO::WaitReadable
                        end
                    end
                end

                unmarshalled = begin Marshal.load(packet.to_s)
                               rescue TypeError => e
                                   raise ProtocolError, "failed to unmarshal received packet: #{e.message}"
                               end
                remote_object_manager.local_object(unmarshalled)

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
                marshalled = Marshal.dump(object.droby_dump(remote_object_manager))
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

