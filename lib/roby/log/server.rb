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
            extend Logger::Forward

            class << self
                attr_reader :logger
            end
            @logger = ::Logger.new(STDERR)
            @logger.level = Logger::WARN
            @logger.progname = "Log Server"
            @logger.formatter = lambda { |severity, time, progname, msg| "#{time.to_hms} (#{progname}) #{msg}\n" }
            @logger.level = ::Logger::INFO

            DEFAULT_PORT  = 20200
            DEFAULT_SAMPLING_PERIOD = 0.1
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
                @event_file = File.open(event_file_path)
            end

            def exec
                Server.info "starting Roby log server on port #{port}"

                @server = TCPServer.new(nil, port)
                server.fcntl(Fcntl::FD_CLOEXEC, 1)

                Server.info "Roby log server listening on port #{port}, sampling period=#{sampling_period}"

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
                        @pending_data[socket] = split_in_chunks(File.read(event_file_path))
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

                Server.debug "#{new_data.size} bytes of new data"

                # Split the data in chunks of DATA_CHUNK_SIZE, and add the
                # chunks in the pending_data hash
                chunks = split_in_chunks(new_data)
                pending_data.each_value do |chunks|
                    chunks.concat(chunks)
                end
            end

            # Tries to send all pending data to the connected clients
            def send_pending_data
                needs_looping = true
                while needs_looping
                    needs_looping = false
                    pending_data.delete_if do |socket, chunks|
                        next if chunks.empty?
                        begin
                            written = socket.write_nonblock(chunks[0])
                            if written == chunks[0].size
                                Server.debug "wrote complete chunk of #{written} bytes to #{socket}"
                                chunks.shift
                                # Loop if we wrote the complete chunk and there
                                # is still stuff to write for this socket
                                needs_looping = !chunks.empty?
                            else
                                Server.debug "wrote partial chunk #{written} bytes instead of #{chunks[0].size} bytes to #{socket}"
                                chunks[0] = chunks[0][written..-1]
                            end
                            false
                        rescue Errno::EAGAIN
                        rescue Exception => e
                            Server.warn "disconnecting from #{socket}: #{e.message}"
                            socket.close
                            true
                        end
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

            def add_listener(&block)
                @listeners << block
            end

            def alive?
                @alive
            end

            def read_and_process_pending
                has_data = select([socket], nil, nil, 0)
                return if !has_data

                buffer = @buffer + socket.read_nonblock(Server::DATA_CHUNK_SIZE)
                Log.debug "#{buffer.size} bytes of data in buffer"
                io = StringIO.new(buffer)
                while !io.eof?
                    pos = io.tell
                    begin
                        data = Marshal.load(io)
                        if data.kind_of?(Hash) && data[:log_format]
                            Roby::Log::Logfile.process_header(data)
                        else
                            @listeners.each do |block|
                                block.call(data)
                            end
                        end
                        Log.debug "processed #{io.tell - pos} bytes of data"
                    rescue Exception => e
                        case e.message
                        when /marshal data too short/
                        when /end of file reached/
                        else
                            raise
                        end
                        @buffer = buffer[pos..-1]
                    end
                end
            rescue Errno::EAGAIN
            end
        end
    end
end
