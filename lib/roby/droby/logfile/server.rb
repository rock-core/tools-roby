# frozen_string_literal: true

require "socket"
require "fcntl"
require "stringio"
require "roby/interface/exceptions"
require "roby/droby/logfile"

module Roby
    module DRoby
        module Logfile
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

                DEFAULT_PORT = 20_200
                DEFAULT_SAMPLING_PERIOD = 0.05
                DATA_CHUNK_SIZE = 512 * 1024

                # The IO we are listening on
                attr_reader :server_io
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

                def initialize(event_file_path, sampling_period, io)
                    @server = io
                    @pending_data = {}
                    @sampling_period = sampling_period
                    @event_file_path = event_file_path
                    @event_file = File.open(event_file_path, "r:BINARY")
                end

                def found_header?
                    @found_header
                end

                # Close all IOs managed by this instance
                #
                # This does NOT close the server IO, which is owned by the
                # caller
                def close
                    close_client_connections
                    @event_file.close
                end

                # Close all currently opened client connections
                #
                # This does NOT close the server IO, which is owned by the
                # caller
                def close_client_connections
                    @pending_data.each_key(&:close)
                    @pending_data.clear
                end

                def exec
                    loop do
                        sockets_with_pending_data = pending_data.find_all do |socket, chunks|
                            !chunks.empty?
                        end.map(&:first)

                        unless sockets_with_pending_data.empty?
                            Server.debug "#{sockets_with_pending_data.size} sockets have pending data"
                        end

                        readable_sockets, =
                            select([server], sockets_with_pending_data, nil, sampling_period)

                        # Incoming connections
                        if readable_sockets && !readable_sockets.empty?
                            socket = Thread.handle_interrupt(Interrupt => :never) do
                                s = server.accept
                                @pending_data[s] = []
                                s
                            end

                            socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
                            socket.fcntl(Fcntl::FD_CLOEXEC, 1)

                            Server.debug "new connection: #{socket}"
                            if found_header?
                                all_data = File.binread(event_file_path,
                                                        event_file.tell - Logfile::PROLOGUE_SIZE,
                                                        Logfile::PROLOGUE_SIZE)

                                Server.debug "  queueing #{all_data.size} bytes of data"
                                chunks = split_in_chunks(all_data)
                            else
                                Server.debug "  log file is empty, not queueing any data"
                                chunks = []
                            end
                            connection_init      = ::Marshal.dump([CONNECTION_INIT, chunks.inject(0) { |s, c| s + c.size }])
                            connection_init_done = ::Marshal.dump(CONNECTION_INIT_DONE)
                            chunks.unshift([connection_init.size].pack("L<") + connection_init)
                            chunks << [connection_init_done.size].pack("L<") + connection_init_done
                            @pending_data[socket] = chunks
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

                    unless found_header?
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

                CONNECTION_INIT = :log_server_connection_init
                CONNECTION_INIT_DONE = :log_server_connection_init_done

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
                            rescue Interrupt
                                raise
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
        end
    end
end
