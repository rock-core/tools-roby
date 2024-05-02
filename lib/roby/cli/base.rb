# frozen_string_literal: true

require "thor"
require "roby"
require "roby/interface/v1"
require "roby/cli/exceptions"
require "roby/app/vagrant"

module Roby
    module CLI
        class Base < Thor
            class_option "debug", desc: "run the app in debug mode",
                                  type: :boolean, default: false
            class_option "log", desc: "configure the loggers",
                                type: :array, default: []

            def self.exit_on_failure?
                true
            end

            no_commands do # rubocop:disable Metrics/BlockLength
                def app
                    Roby.app
                end

                # Configure the app from the global class options
                def setup_common
                    options[:log].each do |spec|
                        mod, level, file = spec.split(":")
                        app.log_setup(mod, level, file)
                    end

                    if options[:debug]
                        app.public_logs = true
                        app.filter_backtraces = false
                        require "roby/app/debug"
                    end

                    Roby.app.shell_interface_port = options[:port] if options[:port]

                    nil
                end

                # Get an interface host and port from the 'host' or 'vagrant' options
                #
                # The 'host' option should be of a hostname/IP, or host:port.
                # The 'vagrant' option should be a vagrant VM name, possibly
                # followed by a port.
                #
                # @return [Hash] either { host: String }, { host: String, port: Integer }
                #     or an empty hash if no relevant option was set
                def parse_host_option
                    if options[:host] && options[:vagrant]
                        raise ArgumentError,
                              "cannot set host and vagrant at the same time"
                    end

                    return {} unless (url = options[:host] || options[:vagrant])

                    result =
                        if (m = /(.*):(\d+)$/.match(url))
                            { host: m[1], port: Integer(m[2]) }
                        else
                            { host: url }
                        end

                    if options[:vagrant]
                        result[:host] = Roby::App::Vagrant.resolve_ip(result[:host])
                    end

                    result
                end

                def interface_host_port
                    host_port = parse_host_option
                    host = host_port[:host] || app.shell_interface_host || "localhost"
                    port = host_port[:port] || app.shell_interface_port ||
                           Interface::DEFAULT_PORT

                    [host, port]
                end

                # Configure the local process as a client to a remote Roby app
                #
                # Use in tools that act through a remote Roby interface
                #
                # (see connect_to_roby_interface)
                def setup_roby_for_interface(
                    app: self.app, retry_connection: false, timeout: nil,
                    retry_period: 0.1, interface_version: 1
                )
                    host, port = interface_host_port

                    app.guess_app_dir
                    app.shell
                    app.single
                    app.load_base_config

                    connect_to_roby_interface(
                        host, port,
                        retry_connection: retry_connection,
                        timeout: timeout, retry_period: retry_period,
                        interface_version: interface_version
                    )
                end

                # Connect to a remote Roby app
                #
                # @param retry_connection whether the connection should be retried
                # @param timeout if retry_connection is true, how long should the
                #    method retry before baling out. Leave to nil to retry forever.
                # @return [Roby::Interface::Client]
                def connect_to_roby_interface( # rubocop:disable Metrics/ParameterLists
                    host, port,
                    app: self.app, retry_connection: false, timeout: nil,
                    retry_period: 0.1, interface_version: 1
                )
                    deadline = Time.now + timeout if retry_connection && timeout
                    interface_m = app.enable_remote_interface_version(interface_version)
                    loop do
                        begin
                            return interface_m.connect_with_tcp_to(host, port)
                        rescue Roby::Interface::ConnectionError => e
                            if !retry_connection || (deadline && Time.now > deadline)
                                raise
                            end

                            Robot.warn "failed to connect to #{host}:#{port}: " \
                                       "#{e.message}, retrying"
                            sleep retry_period
                        end
                    end
                end

                # Pre-configure the Roby app to start execution
                #
                # After calling this, you need to do
                #
                # @example
                #   app.setup
                #   begin
                #       app.run
                #   ensure
                #       app.cleanup
                #   end
                def setup_roby_for_running(run_controllers: false)
                    app.require_app_dir
                    app.public_shell_interface = true
                    app.public_logs = true

                    if (robot = options[:robot])
                        robot_name, robot_type = robot.split(",")
                        app.setup_robot_names_from_config_dir
                        app.robot(robot_name, robot_type)
                    end

                    if run_controllers
                        app.plan.execution_engine
                           .once(description: "run controllers") do
                            app.controllers.each(&:call)
                        end
                    end

                    nil
                end

                def display_notifications(interface)
                    until interface.closed?
                        interface.poll
                        while interface.has_notifications?
                            _, (_, level, message) = interface.pop_notification
                            Robot.send(level.downcase, message)
                        end
                        while interface.has_job_progress?
                            _, (kind, job_id, job_name) = interface.pop_job_progress
                            Robot.info "[#{job_id}] #{job_name}: #{kind}"
                        end
                        sleep 0.01
                    end
                end
            end
        end
    end
end
