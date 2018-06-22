require 'socket'

module Roby
    module Interface
        # An object that publishes a Roby interface using a TCP server
        class TCPServer
            # @return [Interface] the interface object we give access to
            attr_reader :interface
            # @return [::TCPServer] the TCP server we are accepting from
            attr_reader :server
            # @return [Array<Client>] set of currently active clients
            attr_reader :clients
            # Whether the server handler should warn about disconnections
            attr_predicate :warn_about_disconnection?, true
            # Whether a non-comm-related failure will cause the whole Roby app
            # to quit
            attr_predicate :abort_on_exception?, true

            # @return [String] the address this interface is bound to
            def ip_address
                server.local_address.ip_address
            end

            # @return [Integer] the port on which this interface runs
            def ip_port
                server.local_address.ip_port
            end

            # Creates a new interface server on the given port
            #
            # @param [Integer] port
            def initialize(app, host: nil, port: Roby::Interface::DEFAULT_PORT)
                @app = app
                @interface = Interface.new(app)
                @server =
                    begin ::TCPServer.new(host, port)
                    rescue TypeError
                        raise Errno::EADDRINUSE, "#{port} already in use"
                    end
                @clients = Array.new
                @abort_on_exception = true
                @accept_executor = Concurrent::CachedThreadPool.new
                @accept_future = queue_accept_future
                @propagation_handler_id = interface.execution_engine.
                    add_propagation_handler(
                        description: 'TCPServer#process_pending_requests',
                        on_error: :ignore) do
                            process_pending_requests
                        end
                @warn_about_disconnection = false
            end

            def queue_accept_future
                Concurrent::Future.execute(executor: @accept_executor) do
                    socket = @server.accept
                    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
                    socket
                end
            end

            # Returns the port this server is bound to
            #
            # @return [Integer]
            def port
                Roby.warn_deprecated "Interface::TCPServer#port is deprecated in favor "\
                    "of #ip_port to match ruby's Addrinfo API"
                ip_port
            end

            # Creates a server object that will manage the replies on a
            # particular TCP socket
            #
            # @return [Server]
            def create_server(socket)
                Server.new(DRobyChannel.new(socket, false), interface)
            end

            # Number of clients connected to this server
            #
            # @param [Boolean] handshake if true, return only the clients that
            #   have performed their handshake
            # @return [Integer]
            def client_count(handshake: true)
                @clients.count do |c|
                    !handshake || c.performed_handshake?
                end
            end

            # Process all incoming connection requests
            #
            # The new clients are added into the Roby event loop
            def process_pending_requests
                if @accept_future.rejected?
                    raise @accept_future.reason
                elsif @accept_future.fulfilled?
                    clients << create_server(@accept_future.value)
                    @accept_future = queue_accept_future
                end

                exceptions = []
                clients.delete_if do |client|
                    begin
                        client.poll
                        false
                    rescue Exception => e
                        client.close

                        if warn_about_disconnection?
                            Roby::Interface.warn "disconnecting from #{client.client_id}"
                        end

                        next(true) if e.kind_of?(ComError)

                        if abort_on_exception?
                            exceptions << e
                        else
                            Roby.log_exception_with_backtrace(e, Roby::Interface, :warn)
                        end
                        true
                    end
                end

                raise exceptions.first unless exceptions.empty?
            rescue Exception => e
                if abort_on_exception?
                    @app.execution_engine.
                        add_framework_error(e, "Interface::TCPServer")
                else
                    Roby.log_exception_with_backtrace(e, Roby, :warn)
                end
            end

            # Closes this server
            def close
                clients.each do |c|
                    unless c.closed?
                        c.close
                    end
                end
                clients.clear
                if server && !server.closed?
                    server.close
                end
                @accept_executor.shutdown
                interface.execution_engine.
                    remove_propagation_handler(@propagation_handler_id)
            end

            # Whether the given client is handled by this server
            def has_client?(client)
                @clients.include?(client)
            end
        end

        # Connect to a Roby controller interface at this host and port
        #
        # @param [Array<Symbol>] handshake see {Client#initialize}
        # @return [Client] the connected {Client} object
        def self.connect_with_tcp_to(host, port = DEFAULT_PORT,
                marshaller: DRoby::Marshal.new(auto_create_plans: true),
                handshake: [:actions, :commands])
            require 'socket'
            socket = TCPSocket.new(host, port)
            addr = socket.addr(true)
            channel    = DRobyChannel.new(socket, true, marshaller: marshaller)
            Client.new(channel, "#{addr[2]}:#{addr[1]}", handshake: handshake)

        rescue Errno::ECONNREFUSED => e
            raise ConnectionError, "failed to connect to #{host}:#{port}: #{e.message}",
                e.backtrace
        rescue SocketError => e
            raise e, "cannot connect to host '#{host}' port '#{port}': #{e.message}",
                e.backtrace
        rescue ::Exception
            if socket && !socket.closed?
                socket.close
            end
            raise
        end
    end
end
