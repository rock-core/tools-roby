# frozen_string_literal: true

require "roby/interface/rest/server"
require "roby/interface/rest/api"

module Roby
    module Interface
        module REST
            # Generic management of a {Server} as a Roby task
            class Task < Roby::Task
                # The IP on which the REST API is bound
                #
                # Default is 0.0.0.0 (i.e. listen to all IPs)
                argument :host, default: "0.0.0.0"

                # The port on which the REST API should be listening
                #
                # Default is 20202
                #
                # Use 0 for testing purposes, and discover the port using
                # {#actual_port}
                argument :port, default: DEFAULT_REST_PORT

                # The path under which this API will be available, e.g. /api
                #
                # Default is '/api'
                argument :main_route, default: "/api"

                # Whether all requests are to be displayed
                argument :verbose, default: false

                # How many threads should answer
                #
                # Set to 1 to disable multithreading
                argument :threads, default: 1

                event :start do |_event|
                    @rest_server = Server.new(roby_app, **rest_server_args)
                    start_event.achieve_asynchronously do
                        @rest_server.start
                    end
                end

                # List of arguments passed to {Server}
                #
                # @see rack_middlewares rest_storage
                def rest_server_args
                    {
                        host: host, port: port, threads: threads,
                        main_route: main_route, api: rest_api,
                        middlewares: rack_middlewares,
                        storage: rest_storage
                    }
                end

                # List of Rack middlewares that should be added to the thin server
                #
                # @return [Array]
                def rack_middlewares
                    return [] unless verbose

                    Server::VERBOSE_MIDDLEWARES
                end

                # Permanent storage object for REST::Server
                #
                # Overload to inject fields
                #
                # @return [Hash]
                def rest_storage
                    {}
                end

                # The Roby app that is being exposed
                #
                # Defaults to Roby.app. Overload in subclasses to override
                def roby_app
                    Roby.app
                end

                # The REST API that is being exposed
                #
                # Defaults to {API}. Overload in subclasses to override
                def rest_api
                    API
                end

                # The port on which the server is actually listening
                #
                # Differs from {#port} only if {#port] was zero. In this case,
                # the port is available only when the task is already running
                def actual_port
                    @rest_server.port
                end

                # Returns the full URL to the given endpoint
                def url_for(endpoint, host: "localhost")
                    "http://#{host}:#{actual_port}#{main_route}/#{endpoint}"
                end

                poll do
                    stop_event.emit unless @rest_server.running?
                end

                event :stop do |_event|
                    @rest_server.stop(join_timeout: 0)
                end
            end
        end
    end
end
