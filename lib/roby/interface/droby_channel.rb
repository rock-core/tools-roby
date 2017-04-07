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
            # The maximum byte count that the channel can hold on the write side
            # until it bails out
            attr_reader :max_write_buffer_size

            def initialize(io, client, marshaller: DRoby::Marshal.new(auto_create_plans: true), max_write_buffer_size: 25*1024**2)
                @io = io
                @client = client

                @incoming =
                    if client?
                        WebSocket::Frame::Incoming::Client.new(type: :binary)
                    else
                        WebSocket::Frame::Incoming::Server.new(type: :binary)
                    end
                @marshaller = marshaller
                @max_write_buffer_size = max_write_buffer_size
                @write_buffer = String.new
            end

            def write_buffer_size
                @write_buffer.size
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
                deadline = Time.now + timeout if timeout

                begin
                    if data = io.read_nonblock(1024 ** 2)
                        @incoming << data
                    end
                rescue IO::WaitReadable
                end

                while !(packet = @incoming.next)
                    if deadline
                        remaining_time = deadline - Time.now
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

            rescue SystemCallError, EOFError, IOError
                raise ComError, "closed communication"
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

                push_write_data(packet.to_s)
            end

            def push_write_data(new_bytes = nil)
                @write_buffer.concat(new_bytes) if new_bytes
                written_bytes = io.write_nonblock(@write_buffer)
                @write_buffer = @write_buffer[written_bytes..-1]
                !@write_buffer.empty?
            rescue IO::WaitWritable
                if @write_buffer.size > max_write_buffer_size
                    raise ComError, "droby_channel reached an internal buffer size of #{@write_buffer.size}, which is bigger than the limit of #{max_write_buffer_size}, bailing out"
                end
            rescue SystemCallError, IOError, EOFError
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

