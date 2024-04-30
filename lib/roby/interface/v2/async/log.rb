# frozen_string_literal: true

require "roby/droby/plan_rebuilder"
require "roby/droby/logfile/server"
require "roby/droby/logfile/client"

module Roby
    module Interface
        module V2
            module Async
                # Asynchronous access to the log stream
                #
                # Roby logs are purely incremental information, which means that on
                # connection one must process the whole existing log before being
                # able to provide the current state. From a user perspective, this
                # init phase is really overhead, so it's better to avoid updating
                # the UI while the data is being processed. For this reason, the
                # class provides {#on_init_progress} and {#on_init_done} to provide
                # progress information to the user, and start normal processing when
                # init is finished.
                #
                # It must be integrated into your application's event loop by
                # calling {#poll}.
                class Log
                    extend Logger::Hierarchy

                    # The plan rebuilder object, which processes the log stream to
                    # rebuild {#plan}
                    #
                    # @return [Roby::DRoby::PlanRebuilder]
                    attr_reader :plan_rebuilder

                    # The plan self is working on
                    #
                    # @return [Roby::Plan]
                    def plan
                        plan_rebuilder.plan
                    end

                    # Information about the scheduler state
                    #
                    # @return [Schedulers::State]
                    def scheduler_state
                        plan.consolidated_scheduler_state
                    end

                    include Hooks
                    include Hooks::InstanceHooks

                    # @!group Hooks

                    # @!method on_reachable()
                    #   Hooks called when we successfully connected
                    #   @return [void]
                    define_hooks :on_reachable
                    # @!method on_unreachable()
                    #   Hooks called when we got disconnected
                    #   @return [void]
                    define_hooks :on_unreachable
                    # @!method on_init_progress
                    #   (see Roby::DRoby::Logfile::Client#on_init_progress)
                    define_hooks :on_init_progress
                    # @!method on_init_done
                    #   (see Roby::DRoby::Logfile::Client#on_init_done)
                    define_hooks :on_init_done
                    # @!method on_update
                    #   Hooks called when the plan rebuilder processed an update
                    #
                    #   @yieldparam [Integer] cycle_index
                    #   @yieldparam [Time] cycle_time
                    #   @return [void]
                    define_hooks :on_update

                    # @!endgroup

                    attr_reader :host, :port
                    # @return [Roby::DRoby::Logfile::Client,nil] the object used to communicate
                    #   to the server, or nil if we have not managed to connect yet
                    attr_reader :client
                    # The future used to connect to the remote process without blocking
                    # the main event loop
                    attr_reader :connection_future

                    DEFAULT_HOST = "localhost"
                    DEFAULT_PORT = Roby::DRoby::Logfile::Server::DEFAULT_PORT

                    # @api private
                    #
                    # Create a plan rebuilder for use in the async object
                    def default_plan_rebuilder
                        DRoby::PlanRebuilder.new
                    end

                    def initialize(host = DEFAULT_REMOTE_NAME, port: DEFAULT_PORT, connect: true,
                        plan_rebuilder: default_plan_rebuilder)
                        @host = host
                        @port = port
                        @plan_rebuilder = plan_rebuilder
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
                            Roby::DRoby::Logfile::Client.new(host, port)
                        end
                        connection_future.execute
                    end

                    STATE_DISCONNECTED = :disconnected
                    STATE_CONNECTED    = :connected
                    STATE_PENDING_DATA = :pending_data

                    # Active part of the async. This has to be called regularly within
                    # the system's main event loop (e.g. Roby's, Vizkit's or Qt's)
                    #
                    # @return [(Boolean,Boolean)] true if we are connected to the remote server
                    #   and false otherwise
                    def poll(max: 0.1)
                        if connected?
                            if client.read_and_process_pending(max: max)
                                STATE_PENDING_DATA
                            else
                                STATE_CONNECTED
                            end
                        elsif !closed?
                            poll_connection_attempt
                            STATE_DISCONNECTED
                        end
                    rescue Interrupt
                        close
                        raise
                    rescue ComError
                        Log.info "link closed, trying to reconnect"
                        unreachable!
                        unless closed?
                            attempt_connection
                        end
                        false
                    rescue Exception => e
                        Log.warn "error while polling connection, trying to reconnect"
                        Roby.log_exception_with_backtrace(e, Log, :warn)
                        unreachable!
                        unless closed?
                            attempt_connection
                        end
                        false
                    end

                    def unreachable!
                        if client
                            client.close unless client.closed?
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
                        plan_rebuilder&.cycle_index
                    end

                    def cycle_start_time
                        plan_rebuilder&.cycle_start_time
                    end

                    def init_done?
                        client&.init_done?
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
                                run_hook :on_reachable

                                client.on_init_progress do |received, expected|
                                    run_hook :on_init_progress, received, expected
                                end
                                client.on_init_done do
                                    run_hook :on_init_done
                                end
                                client.on_data do |data|
                                    plan_rebuilder.process_one_cycle(data)
                                    cycle = plan_rebuilder.cycle_index
                                    time  = plan_rebuilder.cycle_start_time
                                    Interface.debug "Async update(#{cycle}, #{time})"
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
end
