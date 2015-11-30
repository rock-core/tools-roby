module Roby
    module Interface
        module Async
            module ClientServerTestHelpers
                attr_reader :recorder
                
                def setup
                    super
                    @recorder = flexmock
                    @interfaces = Array.new
                    @interface_servers = Array.new
                end

                def teardown
                    super
                    @interfaces.each(&:close)
                    @interface_servers.each(&:close)
                end

                def default_server_port
                    Distributed::DEFAULT_DROBY_PORT + 1
                end

                def create_server
                    server = Roby::Interface::TCPServer.new(Roby.app, default_server_port)
                    @interface_servers << server
                    server
                end

                def create_client(*args, port: default_server_port, **options, &block)
                    interface = Interface.new(*args, port: default_server_port, **options, &block)
                    @interfaces << interface
                    interface
                end

                def connect(server = nil, **options, &block)
                    server ||= create_server
                    client = create_client('localhost', port: server.port, **options)
                    yield(client) if block_given?
                    client
                ensure
                    while !client.connection_future.complete?
                        sleep 0.1
                        server.process_pending_requests
                    end
                    client.poll
                end

                def process_call(&block)
                    futures = [Concurrent::Future.new(&block),
                               Concurrent::Future.new { @interfaces.each(&:poll) }]
                    result = futures.map do |future|
                        future.execute
                        while !future.complete?
                            @interface_servers.each do |s|
                                s.process_pending_requests
                                s.clients.each(&:poll)
                            end
                            Thread.pass
                        end
                        future.value!
                    end
                    result.first
                end
            end
        end
    end
end
