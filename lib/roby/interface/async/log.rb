require 'roby/log/plan_rebuilder'
require 'roby/log/server'

module Roby
    module Interface
        module Async
            # Asynchronous access to the log stream
            class Log
                attr_reader :plan
                attr_reader :plan_rebuilder

                include Hooks
                include Hooks::InstanceHooks

                # @!method on_reachable()
                #   Hooks called when we successfully connected
                #   @return [void]
                define_hooks :on_reachable
                # @!method on_unreachable()
                #   Hooks called when we got disconnected
                #   @return [void]
                define_hooks :on_unreachable
                # @!method on_update
                #   Hooks called when the plan rebuilder processed an update
                #
                #   @yieldparam [Integer] cycle_index
                #   @yieldparam [Time] cycle_time
                #   @return [void]
                define_hooks :on_update

                attr_reader :host
                attr_reader :port
                # @return [Roby::Log::Client,nil] the object used to communicate
                #   to the server, or nil if we have not managed to connect yet
                attr_reader :client
                # The future used to connect to the remote process without blocking
                # the main event loop
                attr_reader :connection_future

                DEFAULT_HOST = "localhost"
                DEFAULT_PORT = Roby::Log::Server::DEFAULT_PORT

                def initialize(host = DEFAULT_REMOTE_NAME, port: DEFAULT_PORT, connect: true)
                    @host = host
                    @port = port
                    @plan = Roby::Plan.new
                    @plan_rebuilder = Roby::LogReplay::PlanRebuilder.new(plan: plan)
                    @first_connection_attempt = true
                    @closed = false
                    if connect
                        attempt_connection
                    end
                end

                def connected?
                    !!client
                end

                # Start a connection attempt
                def attempt_connection
                    @connection_future = Concurrent::Future.new do
                        Roby::Log::Client.new(host, port)
                    end
                    connection_future.execute
                end

                # Active part of the async. This has to be called regularly within
                # the system's main event loop (e.g. Roby's, Vizkit's or Qt's)
                #
                # @return [Boolean] true if we are connected to the remote server
                #   and false otherwise
                def poll
                    if connected?
                        client.read_and_process_pending
                        true
                    elsif !closed?
                        poll_connection_attempt
                        !!client
                    end
                rescue Interrupt
                    close
                    raise

                rescue ComError
                    Interface.info "link closed, trying to reconnect"
                    unreachable!
                    if !closed?
                        attempt_connection
                    end
                    false
                rescue Exception => e
                    Interface.warn "error while polling connection, trying to reconnect"
                    Roby.log_exception_with_backtrace(e, Interface, :warn)
                    unreachable!
                    if !closed?
                        attempt_connection
                    end
                    false
                end

                def unreachable!
                    if client
                        client.close if !client.closed?
                        @client = nil
                        run_hook :on_unreachable
                    end
                end

                def closed?
                    !!@closed
                end

                def close
                    @closed = true
                    unreachable!
                    plan_rebuilder.clear
                end

                # True if we are connected to a client
                def reachable?
                    !!client
                end

                def cycle_index
                    plan_rebuilder && plan_rebuilder.cycle_index
                end

                def cycle_start_time
                    plan_rebuilder && plan_rebuilder.cycle_start_time
                end

                # Verify the state of the last connection attempt
                #
                # It checks on the last connection attempt, and sets {#client}
                # if it was successful, as well as call the callbacks registered
                # with {#on_reachable}
                def poll_connection_attempt
                    return if client
                    return if closed?

                    if connection_future.complete?
                        case e = connection_future.reason
                        when ConnectionError, ComError
                            Interface.info "Async::Log failed connection attempt: #{e}"
                            attempt_connection
                            if @first_connection_attempt
                                @first_connection_attempt = false
                                run_hook :on_unreachable
                            end
                            nil
                        when NilClass
                            Interface.info "successfully connected"
                            @client = connection_future.value
                            plan_rebuilder.clear
                            @plan = Roby::Plan.new
                            @plan_rebuilder = Roby::LogReplay::PlanRebuilder.new(plan: plan)
                            run_hook :on_reachable

                            client.add_listener do |data|
                                plan_rebuilder.push_data(data)
                                cycle = plan_rebuilder.cycle_index
                                time  = plan_rebuilder.cycle_start_time
                                run_hook :on_update, cycle, time
                            end
                        else
                            raise connection_future.reason
                        end
                    end
                end

                def clear_integrated
                    plan_rebuilder.clear_integrated
                end
            end
        end
    end
end

