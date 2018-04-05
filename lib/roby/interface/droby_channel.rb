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
                @io.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
                @client = client

                @incoming =
                    if client?
                        WebSocket::Frame::Incoming::Client.new(type: :binary)
                    else
                        WebSocket::Frame::Incoming::Server.new(type: :binary)
                    end
                @marshaller = marshaller
                @max_write_buffer_size = max_write_buffer_size
                @read_buffer  = String.new
                @write_buffer = String.new
                @write_thread = nil
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
                @read_thread ||= Thread.current
                if @read_thread != Thread.current
                    raise InternalError, "cross-thread access to droby channel: from #{@read_thread} to #{Thread.current}"
                end

                deadline       = Time.now + timeout if timeout
                remaining_time = timeout

                if packet = @incoming.next
                    return unmarshal_packet(packet)
                end

                while true
                    if IO.select([io], [], [], remaining_time)
                        begin
                            if io.sysread(1024 ** 2, @read_buffer)
                                @incoming << @read_buffer
                            end
                        rescue Errno::EWOULDBLOCK, Errno::EAGAIN
                        end
                    end

                    if packet = @incoming.next
                        return unmarshal_packet(packet)
                    end

                    if deadline
                        remaining_time = deadline - Time.now
                        return if remaining_time < 0
                    end
                end

            rescue SystemCallError, EOFError, IOError
                raise ComError, "closed communication"
            end

            def unmarshal_packet(packet)
                unmarshalled = begin Marshal.load(packet.to_s)
                               rescue TypeError => e
                                   raise ProtocolError, "failed to unmarshal received packet: #{e.message}"
                               end
                marshaller.local_object(unmarshalled)
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

            def reset_thread_guard(read_thread = nil, write_thread = nil)
                @write_thread = read_thread
                @read_thread = write_thread
            end

            # Push queued data
            #
            # The write I/O is buffered. This method pushes data stored within
            # the internal buffer and/or appends new data to it.
            #
            # @return [Boolean] true if there is still data left in the buffe,
            #   false otherwise
            def push_write_data(new_bytes = nil)
                @write_thread ||= Thread.current
                if @write_thread != Thread.current
                    raise InternalError, "cross-thread access to droby channel: from #{@write_thread} to #{Thread.current}"
                end

                @write_buffer.concat(new_bytes) if new_bytes
                written_bytes = io.syswrite(@write_buffer)

                @write_buffer = @write_buffer[written_bytes..-1]
                !@write_buffer.empty?
            rescue Errno::EWOULDBLOCK, Errno::EAGAIN
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

