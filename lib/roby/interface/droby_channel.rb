module Roby
    module Interface
        # A wrapper on top of raw IO that uses droby marshalling to communicate
        class DRobyChannel
            # @return [#read_nonblock,#write] the channel that allows us to communicate to clients
            attr_reader :io
            # @return [Boolean] true if the local process is the client or the
            #   server
            attr_predicate :client?
            # @return [DRoby::Marshal] an object used to marshal or unmarshal
            #   objects to/from the connection
            attr_reader :marshaller

            def initialize(io, client, marshaller: DRoby::Marshal.new(auto_create_plans: true))
                @io = io
                @client = client

                @incoming =
                    if client?
                        WebSocket::Frame::Incoming::Client.new
                    else
                        WebSocket::Frame::Incoming::Server.new
                    end
                @marshaller = marshaller
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

            # Wait until there is something to read on the channel
            #
            # @param [Numeric,nil] timeout a timeout after which the method
            #   will return. Use nil for no timeout
            # @return [Boolean] falsy if the timeout was reached, true
            #   otherwise
            def read_wait(timeout: nil)
                !!IO.select([io], [], [], timeout)
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
                marshaller.local_object(unmarshalled)

            rescue Errno::ECONNRESET, EOFError, IOError
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
                marshalled = Marshal.dump(marshaller.dump(object))
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
            rescue RuntimeError => e
                # Workaround what seems to be a Ruby bug ...
                if e.message =~ /can.t modify frozen IOError/
                    raise ComError, "broken communication channel"
                else raise
                end
            end
        end
    end
end

