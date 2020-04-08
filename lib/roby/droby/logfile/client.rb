# frozen_string_literal: true

require "roby/droby/logfile/reader"

module Roby
    module DRoby
        module Logfile
            # The client part of the event log distribution service
            class Client
                include Hooks
                include Hooks::InstanceHooks

                # @!group Hooks

                # @!method on_init_progress()
                #   @yieldparam [Integer] rx the amount of bytes processed so far
                #   @yieldparam [Integer] init_size the amount of bytes expected to
                #     be received for the init phase
                #   @return [void]
                define_hooks :on_init_progress

                # @!method on_init_done()
                #   Hooks called when we finished processing the initial set of data
                #   @return [void]
                define_hooks :on_init_done

                # @!method on_data
                #   Hooks called with one cycle worth of data
                #
                #   @yieldparam [Array] data the data as logged, unmarshalled (with
                #     Marshal.load) but not unmarshalled by Roby. It is a flat array
                #     of 4-elements tuples of the form (event_name, sec, usec,
                #     args). See {lib/roby/droby/logfile/file_format.md} for more
                #     details.
                #   @return [void]
                define_hooks :on_data

                # @!endgroup

                # The socket through which we are connected to the remote host
                attr_reader :socket
                # The host we are contacting
                attr_reader :host
                # The port on which a connection is created
                attr_reader :port
                # Data that is not a full cycle worth of data (i.e. buffer needed
                # for packet reassembly)
                attr_reader :buffer
                # The amount of bytes received so far
                attr_reader :rx

                def initialize(host, port = Server::DEFAULT_PORT)
                    @host = host
                    @port = port
                    @buffer = String.new

                    @rx = 0
                    @socket =
                        begin TCPSocket.new(host, port)
                        rescue Errno::ECONNREFUSED => e
                            raise Interface::ConnectionError, "cannot contact Roby log server at '#{host}:#{port}': #{e.message}"
                        end
                    socket.fcntl(Fcntl::FD_CLOEXEC, 1)
                    socket.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
                rescue Exception
                    socket&.close
                    raise
                end

                def disconnect
                    @socket.close
                end

                def close
                    @socket.close
                end

                def closed?
                    @socket.closed?
                end

                def add_listener(&block)
                    on_data(&block)
                end

                def alive?
                    @alive
                end

                # Read and process data
                #
                # @param [Numeric] max max time we can spend processing. The method
                #   will at least process one cycle worth of data regardless of this
                #   parameter
                # @return [Boolean] true if the last call processed something and
                #   false otherwise. It is an indicator of whether there could be
                #   still some data pending
                def read_and_process_pending(max: 0)
                    current_time = start = Time.now
                    while (processed_one_cycle = read_and_process_one_pending_cycle) && (current_time - start) <= max
                        current_time = Time.now
                    end
                    processed_one_cycle
                end

                # The number of bytes that have to be transferred to finish
                # initializing the connection
                attr_reader :init_size

                def init_done?
                    @init_done
                end

                # @api private
                #
                # Read data from the underlying socket
                #
                # @return [Boolean] true if some data was read, false otherwise
                def read_from_socket(size = Server::DATA_CHUNK_SIZE)
                    @buffer.concat(socket.read_nonblock(size))
                    true
                rescue EOFError, Errno::ECONNRESET, Errno::EPIPE => e
                    raise Interface::ComError, e.message, e.backtrace
                rescue Errno::EAGAIN
                    false
                end

                # @api private
                #
                # Reads the socket and processes at most one cycle of data
                #
                # @return [Boolean] whether there might be one more cyc
                def read_and_process_one_pending_cycle
                    Logfile.debug "#{buffer.size} bytes of data in buffer"

                    data_size = nil
                    loop do
                        if buffer.size > 4
                            data_size = buffer.unpack1("L<")
                            Logfile.debug "expecting data block of #{data_size} bytes"
                            break if buffer.size >= data_size + 4

                            read_success = read_from_socket(
                                [Server::DATA_CHUNK_SIZE, buffer.size - data_size].max
                            )
                            return unless read_success
                        else
                            return unless read_from_socket
                        end
                    end

                    if data_size && (buffer.size >= data_size + 4)
                        cycle_data = buffer[4, data_size]
                        @buffer = buffer[(data_size + 4)..-1]
                        data = ::Marshal.load_with_missing_constants(cycle_data)
                        if data.kind_of?(Hash)
                            Reader.process_options_hash(data)
                        elsif data == Server::CONNECTION_INIT_DONE
                            @init_done = true
                            run_hook :on_init_done
                        elsif data[0] == Server::CONNECTION_INIT
                            @init_size = data[1]
                        else
                            @rx += (data_size + 4)
                            unless init_done?
                                run_hook :on_init_progress, rx, init_size
                            end
                            run_hook :on_data, data
                        end
                        Logfile.debug "processed #{data_size} bytes of data, "\
                                      "#{@buffer.size} remaining in buffer"
                        true
                    end
                rescue Errno::EAGAIN
                end
            end
        end
    end
end
