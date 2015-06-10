require 'socket'
require 'fcntl'
require 'stringio'

module Roby
    module Log
        # This is the server part of the log distribution mechanism
        #
        # It is basically a file distribution mechanism: it "listens" to the
        # event log file and sends new data to the clients that are connected to
        # it.
        #
        # When a client connects, it will send the complete file
	class Server
            extend Logger::Hierarchy
            make_own_logger("Log Server", Logger::WARN)

            DEFAULT_PORT  = 20200
            DEFAULT_SAMPLING_PERIOD = 0.05
            DATA_CHUNK_SIZE = 1024*16

            # The port we are listening on
            attr_reader :port
            # The sampling period (in seconds)
            attr_reader :sampling_period
            # The path to the event file this server is listening to
            attr_reader :event_file_path
            # The IO object that we use to read the event file
            attr_reader :event_file
            # A mapping from socket to data chunks representing the data that
            # should be sent to a particular client
            attr_reader :pending_data
            # The server socket
            attr_reader :server

            def initialize(event_file_path, sampling_period = DEFAULT_SAMPLING_PERIOD, port = DEFAULT_PORT)
                @port = port
                @pending_data = Hash.new
                @sampling_period = sampling_period
                @event_file_path = event_file_path
                if File.respond_to?(:binread) # Ruby 1.9, need to take care about the encoding
                    @event_file = File.open(event_file_path, 'r:BINARY')
                else
                    @event_file = File.open(event_file_path)
                end
            end

            def found_header?
                @found_header
            end

            def exec
                @server =
                    begin TCPServer.new(port)
                    rescue TypeError # Workaround for https://bugs.ruby-lang.org/issues/10203
                        raise Errno::EADDRINUSE, "Address already in use - bind(2) for \"0.0.0.0\" port #{port}"
                    end
                server.fcntl(Fcntl::FD_CLOEXEC, 1)

                raise_level = (port != DEFAULT_PORT || sampling_period != DEFAULT_SAMPLING_PERIOD)
                level = if raise_level then
                            :warn
                        else :info
                        end

                Server.send(level, "Roby log server listening on port #{port}, sampling period=#{sampling_period}")

                while true
                    sockets_with_pending_data = pending_data.find_all do |socket, chunks|
                        !chunks.empty?
                    end.map(&:first)
                    if !sockets_with_pending_data.empty?
                        Server.debug "#{sockets_with_pending_data.size} sockets have pending data"
                    end

                    readable_sockets, _ =
                        select([server], sockets_with_pending_data, nil, sampling_period)

                    # Incoming connections
                    if readable_sockets && !readable_sockets.empty?
                        socket = server.accept
                        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
                        socket.fcntl(Fcntl::FD_CLOEXEC, 1)

                        Server.debug "new connection: #{socket}"
                        if found_header?
                            all_data =
                                if File.respond_to?(:binread)
                                    File.binread(event_file_path, 
                                              event_file.tell - Logfile::PROLOGUE_SIZE,
                                              Logfile::PROLOGUE_SIZE)
                                else
                                    File.read(event_file_path, 
                                              event_file.tell - Logfile::PROLOGUE_SIZE,
                                              Logfile::PROLOGUE_SIZE)
                                end

                            Server.debug "  queueing #{all_data.size} bytes of data"
                            @pending_data[socket] = split_in_chunks(all_data)
                        else
                            Server.debug "  log file is empty, not queueing any data"
                        end
                    end

                    # Read new data
                    read_new_data
                    # Send data to our peers
                    send_pending_data
                end
            rescue Exception
                pending_data.each_key(&:close)
                raise
            end

            # Splits the data block in +data+ in blocks of size DATA_CHUNK_SIZE
            def split_in_chunks(data)
                result = []

                index = 0
                while index != data.size
                    remaining = (data.size - index)
                    if remaining > DATA_CHUNK_SIZE
                        result << data[index, DATA_CHUNK_SIZE]
                        index += DATA_CHUNK_SIZE
                    else
                        result << data[index, remaining]
                        index = data.size
                    end
                end
                result
            end

            # Reads new data from the underlying file and queues it to dispatch
            # for our clients
            def read_new_data
                new_data = event_file.read
                return if new_data.empty?

                if !found_header?
                    if new_data.size >= Logfile::PROLOGUE_SIZE
                        # This will read and validate the prologue
                        Logfile.read_prologue(StringIO.new(new_data))
                        new_data = new_data[Logfile::PROLOGUE_SIZE..-1]
                        @found_header = true
                    else
                        # Go back to the beginning of the file so that, next
                        # time, we read the complete prologue again
                        event_file.rewind
                        return
                    end
                end

                # Split the data in chunks of DATA_CHUNK_SIZE, and add the
                # chunks in the pending_data hash
                new_chunks = split_in_chunks(new_data)
                pending_data.each_value do |chunks|
                    chunks.concat(new_chunks)
                end
            end

            # Tries to send all pending data to the connected clients
            def send_pending_data
                needs_looping = true
                while needs_looping
                    needs_looping = false
                    pending_data.delete_if do |socket, chunks|
                        if chunks.empty?
                            # nothing left to send for this socket
                            next
                        end

                        buffer = chunks.shift
                        while !chunks.empty? && (buffer.size + chunks[0].size < DATA_CHUNK_SIZE)
                            buffer.concat(chunks.shift)
                        end
                        Server.debug "sending #{buffer.size} bytes to #{socket}"


                        begin
                            written = socket.write_nonblock(buffer)
                        rescue Errno::EAGAIN
                            Server.debug "cannot send: send buffer full"
                            chunks.unshift(buffer)
                            next
                        rescue Exception => e
                            Server.warn "disconnecting from #{socket}: #{e.message}"
                            e.backtrace.each do |line|
                                Server.warn "  #{line}"
                            end
                            socket.close
                            next(true)
                        end

                        remaining = buffer.size - written
                        if remaining == 0
                            Server.debug "wrote complete chunk of #{written} bytes to #{socket}"
                            # Loop if we wrote the complete chunk and there
                            # is still stuff to write for this socket
                            needs_looping = !chunks.empty?
                        else
                            Server.debug "wrote partial chunk #{written} bytes instead of #{buffer.size} bytes to #{socket}"
                            chunks.unshift(buffer[written, remaining])
                        end
                        false
                    end
                end
            end
        end

        # The client part of the event log distribution service
        class Client
            # The socket through which we are connected to the remote host
            attr_reader :socket
            # The host we are contacting
            attr_reader :host
            # The port on which a connection is created
            attr_reader :port
            # Data that is not a full cycle worth of data (i.e. buffer needed
            # for packet reassembly)
            attr_reader :buffer

            def initialize(host, port = Server::DEFAULT_PORT)
                @host = host
                @port = port
                @buffer = ""

                @socket =
                    begin TCPSocket.new(host, port)
                    rescue Errno::ECONNREFUSED => e
                        raise e.class, "cannot contact Roby log server at '#{host}:#{port}': #{e.message}"
                    end
                socket.fcntl(Fcntl::FD_CLOEXEC, 1)
                socket.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)

                @listeners = Array.new
            end

            def disconnect
                @socket.close
            end

            def add_listener(&block)
                @listeners << block
            end

            def alive?
                @alive
            end

            def read_and_process_pending
                buffer = @buffer + socket.read_nonblock(Server::DATA_CHUNK_SIZE)
                Log.debug "#{buffer.size} bytes of data in buffer"

                while true
                    if buffer.size < 4
                        break
                    end

                    data_size = buffer.unpack('I').first
                    if buffer.size > data_size + 4
                        data = Marshal.load_with_missing_constants(buffer[4, data_size])
                        if data.kind_of?(Hash)
                            Roby::Log::Logfile.process_options_hash(data)
                        else
                            @listeners.each do |block|
                                block.call(data)
                            end
                        end
                        buffer = buffer[(data_size + 4)..-1]
                    else
                        break
                    end
                end

                @buffer = buffer
            rescue Errno::EAGAIN
            end
        end
    end
end
