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
                @server = ::TCPServer.new(port)
                @clients = Array.new
                @propagation_handler_id = interface.engine.add_propagation_handler(:on_error => :ignore) do
                    process_pending_requests
                end
            end

            # Process all incoming connection requests
            #
            # The new clients are added into the Roby event loop
            def process_pending_requests
                while pending = select([server] + clients, [], [], 0)
                    pending = pending[0]
                    if pending.delete(server)
                        socket = server.accept
                        server = Server.new(DRobyChannel.new(socket, false), interface)
                        clients << server
                    end
                    pending.delete_if do |client|
                        begin
                            client.poll
                        rescue ComError => e
                            Roby::Interface.warn "disconnecting from client: #{e}"
                            client.close
                            clients.delete(client)
                        end
                    end
                end
            end

            # Closes this server
            def close
                server.close
                interface.engine.remove_propagation_handler(@propagation_handler_id)
            end
        end

        # Connect to a Roby controller interface at this host and port
        #
        # @return [Client] the client object that gives access
        def self.connect_with_tcp_to(host, port)
            socket = TCPSocket.new(host, port)
            client = Client.new(DRobyChannel.new(socket, true))
            client.handshake
            client
        rescue Errno::ECONNREFUSED
            raise ConnectionError, "failed to connect to #{host}:#{port}"
        end
    end
end

