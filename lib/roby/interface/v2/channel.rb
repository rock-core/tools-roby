# frozen_string_literal: true

module Roby
    module Interface
        # A wrapper on top of raw IO that uses droby marshalling to communicate
        class Channel
            # @return [#read_nonblock,#write] the channel that allows us to
            #   communicate to clients
            attr_reader :io

            # @return [Boolean] true if the local process is the client or the
            #   server
            attr_predicate :client?

            # The maximum byte count that the channel can hold on the write side
            # until it bails out
            attr_reader :max_write_buffer_size

            # This is a workaround for a very bad performance behavior on first
            # load. These classes are auto-loaded and it takes forever to load
            # them in multithreaded contexts.
            WEBSOCKET_CLASSES = [
                WebSocket::Frame::Outgoing::Client,
                WebSocket::Frame::Outgoing::Server,
                WebSocket::Frame::Incoming::Client,
                WebSocket::Frame::Incoming::Server
            ].freeze

            ALLOWED_BASIC_TYPES = [
                TrueClass, FalseClass, NilClass, Integer, Float, String, Symbol, Time,
                Range
            ].freeze

            def initialize(
                io, client,
                max_write_buffer_size: 25 * 1024**2
            )
                @io = io
                @io.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
                @client = client
                @websocket_packet =
                    if client
                        WebSocket::Frame::Outgoing::Client
                    else
                        WebSocket::Frame::Outgoing::Server
                    end

                @incoming =
                    if client?
                        WebSocket::Frame::Incoming::Client.new(type: :binary)
                    else
                        WebSocket::Frame::Incoming::Server.new(type: :binary)
                    end
                @max_write_buffer_size = max_write_buffer_size
                @read_buffer = String.new
                @write_buffer = String.new
                @write_thread = nil

                @marshallers = {}
                @resolved_marshallers = {}
                Protocol.setup_channel(self)
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
                IO.select([io], [], [], timeout)
            end

            # Read one packet from {#io} and unmarshal it
            #
            # @return [Object,nil] returns the unmarshalled object, or nil if no
            #   full object can be found in the data received so far
            def read_packet(timeout = 0)
                guard_read_thread

                if (packet = @incoming.next)
                    return unmarshal_packet(packet)
                end

                read_packet_from_io(timeout)
            end

            def read_packet_from_io(timeout)
                deadline       = Time.now + timeout if timeout
                remaining_time = timeout

                loop do
                    read_data_from_io(remaining_time)

                    if (packet = @incoming.next)
                        return unmarshal_packet(packet)
                    end

                    if deadline
                        remaining_time = deadline - Time.now
                        return if remaining_time < 0
                    end
                end
            rescue SystemCallError, IOError
                raise ComError, "closed communication"
            end

            def read_data_from_io(remaining_time)
                return unless IO.select([@io], [], [], remaining_time)

                @incoming << @read_buffer if io.sysread(1024**2, @read_buffer)
            rescue Errno::EWOULDBLOCK, Errno::EAGAIN # rubocop:disable Lint/SuppressedException
            end

            def unmarshal_packet(packet)
                Marshal.load(packet.to_s) # rubocop:disable Security/MarshalLoad
            rescue TypeError => e
                raise ProtocolError,
                      "failed to unmarshal received packet: #{e.message}"
            end

            # Write one ruby object (usually an array) as a marshalled packet and
            # send it to {#io}
            #
            # @param [Object] object the object to be sent
            # @return [void]
            def write_packet(object)
                marshalled = marshal_object(object)
                packet = @websocket_packet.new(data: marshalled, type: :binary)
                push_write_data(packet.to_s)
            end

            def marshal_object(object)
                object = marshal_filter_object(object)
                Marshal.dump(object)
            rescue TypeError => e
                invalid = self.class.find_invalid_marshalling_object(object)
                message = "failed to marshal #{invalid} of class "\
                          "#{invalid.class} in #{object}: #{e.message}"
                Marshal.dump report_error(message)
            rescue RuntimeError => e
                message = "failed to marshal #{object}: #{e.message}"
                Marshal.dump report_error(message)
            end

            def report_error(message)
                Roby::Interface.warn message
                caller.each { Roby::Interface.warn("  #{_1}") }

                Protocol::Error.new(message: message, backtrace: [])
            end

            def self.find_invalid_marshalling_object(object)
                case object
                when Array, Struct, Hash
                    object.each do
                        obj = find_invalid_marshalling_object(_1)
                        return obj if obj
                    end
                else
                    begin
                        ::Marshal.dump(object)
                        nil
                    rescue TypeError
                        object
                    end
                end
            end

            def allow_classes(*classes)
                add_marshaller(*classes) { _2 }
            end

            # Define a custom marshaller for objects of the given class
            #
            # @param [Array<Class>] classes the classes to use the given marshaller
            #   for. This will match instances of subclasses as well. The first marshaller
            #   defined for a given instance will win.
            # @yieldparam [Channel] channel
            # @yieldparam [Object] object the object to marshal
            # @yieldreturn [Object] the marshalled object
            def add_marshaller(*classes, &block)
                classes.each { @marshallers[_1] = block }
                @resolved_marshallers = @marshallers.dup
            end

            None = Object.new

            def marshal_filter_object(object)
                marshalled = marshal_basic_object(object)
                return marshalled if marshalled != None

                if (marshaller = find_marshaller(object))
                    return marshaller[self, object]
                end

                message = "object '#{object}' of class #{object.class} "\
                          "not allowed on this interface"
                report_error(message)
            end

            def marshal_basic_object(object) # rubocop:disable Metrics/AbcSize
                case object
                when Array
                    object.map { marshal_filter_object(_1) }
                when Set
                    object.each_with_object(Set.new) { _2 << marshal_filter_object(_1) }
                when Hash
                    object.transform_values { marshal_filter_object(_1) }
                when Struct
                    object = object.dup
                    object.each_pair { object[_1] = marshal_filter_object(_2) }
                    object
                when *ALLOWED_BASIC_TYPES
                    object
                else
                    None
                end
            end

            def find_marshaller(object)
                if (block = @resolved_marshallers[object.class])
                    return block
                end

                _, block =
                    @marshallers
                    .find_all { |klass, _| object.kind_of?(klass) }
                    .min_by { _1 }
                @resolved_marshallers[object.class] = block
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
                guard_write_thread

                @write_buffer.concat(new_bytes) if new_bytes
                written_bytes = io.syswrite(@write_buffer)

                @write_buffer = @write_buffer[written_bytes..-1]
                !@write_buffer.empty?
            rescue Errno::EWOULDBLOCK, Errno::EAGAIN
                guard_buffer_size
            rescue SystemCallError, IOError
                raise ComError, "broken communication channel"
            rescue RuntimeError => e
                # Workaround what seems to be a Ruby bug ...
                if e.message =~ /can.t modify frozen IOError/
                    raise ComError, "broken communication channel"
                end

                raise
            end

            def guard_write_thread
                @write_thread ||= Thread.current
                return if @write_thread == Thread.current

                raise InternalError,
                      "cross-thread access to channel: "\
                      "from #{@write_thread} to #{Thread.current}"
            end

            def guard_read_thread
                @read_thread ||= Thread.current
                return if @read_thread == Thread.current

                raise InternalError,
                      "cross-thread access to droby channel: "\
                      "from #{@read_thread} to #{Thread.current}"
            end

            def guard_buffer_size
                return if @write_buffer.size <= max_write_buffer_size

                raise ComError,
                      "channel reached an internal buffer size of "\
                      "#{@write_buffer.size}, which is bigger than the limit "\
                      "of #{max_write_buffer_size}, bailing out"
            end
        end
    end
end
