require 'eventmachine'
require 'rack'
require 'thin'
require 'rest-client'
require 'grape'
require 'roby/interface/rest/helpers'

module Roby
    module Interface
        module REST
            # A thin-based server class that provides the REST API in-process
            class Server
                # The application that is being exposed by this server
                attr_reader :app

                # The host the server is bound to
                #
                # @return [String]
                attr_reader :host

                # The port the server is bound to
                #
                # If zero is originally given to {#initialize} for a TCP server
                # setup, this will be changed to the actual port number when it
                # is known
                #
                # @return [Integer]
                attr_reader :port

                # Create a new server
                #
                # @param [Roby::Application] the application this server will
                #   be exposing
                # @param [String] host the host the server should bind to. Either
                #   an IP for a TCP server, or a path to a UNIX socket
                # @param [Integer] port the port the server should bind to if it
                #   is a TCP server. Set to zero to auto-allocate. Ignored if 'host'
                #   is the path to a UNIX socket.
                def initialize(app, host: '0.0.0.0', port: Roby::Interface::DEFAULT_REST_PORT,
                               api: REST::API)
                    @app = app
                    @host = host
                    @interface = Interface.new(app)
                    @wait_start = Concurrent::IVar.new

                    api = self.class.attach_api_to_interface(api, @interface)
                    rack_app = Rack::Builder.new do
                        yield(self) if block_given?

                        map '/api' do
                            run api
                        end
                    end
                    @server = Thin::Server.new(host, port, rack_app, signals: false)
                    @server.silent = true
                    if @server.backend.respond_to?(:port)
                        @original_port = port
                        if port != 0
                            @port = port
                        end
                    else
                        @original_port = @port = nil
                    end
                end

                # @api private
                #
                # Helper method that transforms a Grape API class so that it
                # gets an #interface accessor that provides the interface
                # object the API is meant to work on
                def self.attach_api_to_interface(api, interface)
                    storage = Hash.new
                    Class.new do
                        define_method(:call) do |env|
                            env['roby.interface'] = interface
                            env['roby.storage'] = storage
                            api.call(env)
                        end
                    end.new
                end

                # Starts the server
                #
                # @param [Numeric,nil] wait_timeout how long the method should
                #   wait for the server to be started and functional. Set to
                #   zero to not wait at all, and nil to wait forever
                # @raise [Timeout] if wait_timeout is non-zero and the timeout
                #   was reached while waiting for the server to start
                def start(wait_timeout: 5)
                    @server_thread = create_thin_thread(@server, @wait_start)
                    if wait_timeout != 0
                        wait_start(timeout: wait_timeout)
                    end
                end

                # Whether the server is running
                def running?
                    @server_thread && @server_thread.alive?
                end

                # @api private
                #
                # Create the underlying thread that starts the thin server
                def create_thin_thread(server, sync)
                    Thread.new do
                        server.backend.start do
                            if server.backend.respond_to?(:port)
                                sync.set(server.backend.port)
                            else
                                sync.set(nil)
                            end
                        end
                    end
                end

                # The server port
                #
                # If the port given to {#initialize} was zero, the method will
                # return the actual port only if the server is fully started.
                # Set timeout to a value greater than zero or nil to
                # synchronize on it.
                #
                # @param [Integer,nil] timeout how long the method is allowed
                #   to wait for the server to start, in case the original port
                #   was set to zero
                # @raise [Timeout]
                def port(timeout: 0)
                    if @port
                        return @port
                    elsif !@original_port
                        return nil
                    else
                        wait_start(timeout: timeout)
                        @port = @wait_start.value!
                    end
                end

                # Exception raised by the methods that could time out
                class Timeout < RuntimeError; end

                # Wait for the server to be properly booted
                #
                # @param [Numeric,nil] timeout how long the method is allowed to block
                #   waiting for the server to start. Set to zero to not wait at all
                #   and nil to wait forever
                # @raise [Timeout]
                def wait_start(timeout: 10)
                    @wait_start.wait(timeout)
                    if !@wait_start.complete?
                        raise Timeout, "timed out while waiting for the server to start"
                    end
                end

                # Asks the server to stop
                #
                # @param [Numeric,nil] join_timeout how long the method is allowed
                #   to block waiting for the thread to stop. Set to zero to not
                #   wait at all, and nil to wait forever
                # @raise [Timeout]
                def stop(join_timeout: 10)
                    EventMachine.next_tick { @server.stop! }
                    if join_timeout != 0
                        join(timeout: join_timeout)
                    end
                end

                # Waits for the server to stop
                #
                # @param [Numeric,nil] timeout how long the method is allowed
                #   to block waiting for the thread to stop. Set to zero to not
                #   wait at all, and nil to wait forever
                # @raise [Timeout]
                def join(timeout: nil)
                    if timeout
                        if !@server_thread.join(timeout)
                            raise Timeout, "timed out while waiting for the server to stop"
                        end
                    else
                        @server_thread.join
                    end
                end

                # Exception raised by {#server_alive?} if there is a server at
                # the expected host and port, but not a Roby REST server
                class InvalidServer < RuntimeError; end

                # (see Server.server_alive?)
                def server_alive?
                    if !@wait_start.complete?
                        return false
                    else
                        self.class.server_alive?('localhost', port)
                    end
                end

                # Tests whether the server is actually alive
                #
                # It accesses the 'ping' endpoint and verifies its result
                #
                # @raise InvalidServer if there is a server at the expected
                #   host and port, but not a Roby REST server
                def self.server_alive?(host, port)
                    test_value = rand(10)
                    returned_value = RestClient.
                        get("http://#{host}:#{port}/api/ping", params: { value: test_value })
                    if test_value != Integer(returned_value)
                        raise InvalidServer, "unexpected server answer to 'ping', expected #{test_value} but got #{returned_value}"
                    end
                    true
                rescue Errno::ECONNREFUSED => e
                    false
                rescue RestClient::Exception => e
                    raise InvalidServer, "unexpected server answer to 'ping': #{e}"
                end
            end
        end
    end
end

