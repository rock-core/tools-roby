# frozen_string_literal: true

module Roby
    module Interface
        module Async
            module ClientServerTestHelpers
                attr_reader :recorder

                def setup
                    super
                    @recorder = flexmock
                    @interfaces = []
                    @interface_servers = []
                end

                def teardown
                    super
                    @interfaces.each(&:close)
                    @interface_servers.each(&:close)
                end

                def app
                    Roby.app
                end

                def available_server_port
                    server = ::TCPServer.new(nil, 0)
                    port = server.local_address.ip_port
                    server.close
                    port
                end

                def create_server(port: 0)
                    server = Roby::Interface::TCPServer.new(Roby.app, port: port)
                    @interface_servers << server
                    server
                end

                def create_client(*args, port:, **options, &block)
                    interface = Interface.new(*args, port: port, **options, &block)
                    @interfaces << interface
                    interface
                end

                def connect(server = nil, **options, &block)
                    server ||= create_server
                    client = create_client("localhost", port: server.ip_port, **options)
                    yield(client) if block_given?
                    client
                ensure
                    until client.connection_future.complete?
                        sleep 0.01
                        server.process_pending_requests
                    end
                    client.poll
                end

                def process_call(&block)
                    poll_async_interfaces = Concurrent::Future.new do
                        @interfaces.each do |async_interface|
                            async_interface.client&.io&.reset_thread_guard
                            async_interface.poll
                            async_interface.client&.io&.reset_thread_guard
                        end
                    end
                    futures = [Concurrent::Future.new(&block), poll_async_interfaces]
                    result = futures.map do |future|
                        future.execute
                        until future.complete?
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
