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

            # Creates a new interface server on the given port
            #
            # @param [Integer] port
            def initialize(app, port = Roby::Distributed::DEFAULT_DROBY_PORT)
                @interface = Interface.new(app)
                @server =
                    begin ::TCPServer.new(port)
                    rescue TypeError
                        raise Errno::EADDRINUSE, "#{port} already in use"
                    end
                @clients = Array.new
                @propagation_handler_id = interface.engine.add_propagation_handler(:on_error => :ignore) do
                    process_pending_requests
                end
            end

            # Returns the port this server is bound to
            #
            # @return [Integer]
            def port
                server.addr(false)[1]
            end

            # Creates a server object that will manage the replies on a
            # particular TCP socket
            #
            # @return [Server]
            def create_server(socket)
                Server.new(DRobyChannel.new(socket, false), interface)
            end

            # Process all incoming connection requests
            #
            # The new clients are added into the Roby event loop
            def process_pending_requests
                while pending = select([server] + clients, [], [], 0)
                    pending = pending[0]
                    if pending.delete(server)
                        socket = server.accept
                        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
                        server = create_server(socket)
                        clients << server
                    end
                    pending.delete_if do |client|
                        begin
                            client.poll
                        rescue ComError => e
                            Roby::Interface.warn "disconnecting from #{client.client_id}: #{e}"
                            client.close
                            clients.delete(client)
                        end
                    end
                end
            end

            # Closes this server
            def close
                clients.each do |c|
                    if !c.closed?
                        c.close
                    end
                end
                clients.clear
                if server && !server.closed?
                    server.close
                end
                interface.engine.remove_propagation_handler(@propagation_handler_id)
            end
        end

        # Connect to a Roby controller interface at this host and port
        #
        # @return [Client] the client object that gives access
        def self.connect_with_tcp_to(host, port, remote_object_manager: Distributed::DumbManager)
            socket = TCPSocket.new(host, port)
            addr = socket.addr(true)
            Client.new(DRobyChannel.new(socket, true, remote_object_manager: remote_object_manager),
                       "#{addr[2]}:#{addr[1]}")

        rescue Errno::ECONNREFUSED
            raise ConnectionError, "failed to connect to #{host}:#{port}"
        rescue ::Exception
            if socket && !socket.closed?
                socket.close
            end
            raise
        end
    end
end

