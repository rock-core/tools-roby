# frozen_string_literal: true

require "thor"
require "roby"
require "roby/cli/exceptions"
require "roby/cli/gen_main"

module Roby
    module CLI
        class Main < Thor
            def self.exit_on_failure?
                true
            end

            desc "add_robot ROBOT_NAME", "Deprecated, use 'gen robot' instead",
                 hide: true # backward-compatibility only
            def add_robot(robot_name)
                gen("robot", robot_name)
            end

            desc "init [DIR]", "Deprecated, use 'gen app' instead",
                 hide: true # backward-compatibility only
            def init(*dir)
                gen("app", *dir)
            end

            desc "gen [GEN_MODE]", "scaffold generation"
            subcommand :gen, GenMain

            no_commands do
                def parse_host_option
                    if url = options[:host]
                        if url =~ /(.*):(\d+)$/
                            Hash[host: $1, port: Integer($2)]
                        else
                            Hash[host: url]
                        end
                    elsif url = options[:vagrant]
                        require "roby/app/vagrant"
                        if vagrant_name =~ /(.*):(\d+)$/
                            vagrant_name, port = $1, Integer($2)
                        end
                        Hash[host: Roby::App::Vagrant.resolve_ip(vagrant_name),
                             port: port]
                    else {}
                    end
                end

                def setup_interface(app = Roby.app, retry_connection: false, timeout: nil)
                    host_port = parse_host_option
                    host = host_port[:host] || app.shell_interface_host || "localhost"
                    port = host_port[:port] || app.shell_interface_port || Interface::DEFAULT_PORT

                    app.guess_app_dir
                    app.shell
                    app.single
                    app.load_base_config

                    interface = nil
                    if retry_connection && timeout
                        deadline = Time.now + timeout
                    end
                    loop do
                        begin
                            return Roby::Interface.connect_with_tcp_to(host, port)
                        rescue Roby::Interface::ConnectionError => e
                            if deadline && deadline > Time.now
                                Robot.warn "failed to connect to #{host}:#{port}: #{e.message}, retrying"
                                sleep 0.05
                            elsif !retry_connection || deadline
                                raise
                            end
                        rescue Interrupt
                            raise
                        end
                    end
                end

                def display_notifications(interface)
                    until interface.closed?
                        interface.poll
                        while interface.has_notifications?
                            _, (source, level, message) = interface.pop_notification
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

            desc "quit", "quits a running Roby application to be available"
            option :host, desc: "the host[:port] to connect to",
                          type: :string
            option :retry,
                   desc: "retry to connect instead of failing right away",
                   long_desc: "The argument is an optional timeout in seconds.\nThe command will retry forever if not given",
                   type: :numeric, lazy_default: 0
            def quit
                timeout = options[:retry] if options[:retry] != 0
                interface = setup_interface(
                    retry_connection: !!options[:retry],
                    timeout: timeout)
                Robot.info "connected"
                interface.quit
                begin
                    Robot.info "waiting for remote app to terminate"
                    display_notifications(interface)
                rescue Roby::Interface::ComError
                    Robot.info "closed communication"
                rescue Interrupt
                    Robot.info "CTRL+C detected, forcing remote quit. Press CTRL+C once more to terminate this script"
                    interface.quit
                    display_notifications(interface)
                end
            ensure
                interface.close if interface && !interface.closed?
            end

            desc "wait", "waits for a running Roby application to be available",
                 hide: true
            option :host, desc: "the host[:port] to connect to",
                          type: :string
            option :timeout,
                   desc: "how long the command should wait, in seconds (default is 10s)",
                   type: :numeric, default: 10
            def wait
                interface = setup_interface(
                    retry_connection: true,
                    timeout: options[:timeout])
            ensure
                interface.close if interface && !interface.closed?
            end

            desc "check", "verifies that the configuration is valid",
                 hide: true
            long_desc "This loads the specified robot configuration,"\
                " but does not start the app itself."\
                " Use this to validate the current configuration"
            option :robot, aliases: "r", default: "default",
                           desc: "the robot name, separate name and type a comma"
            option :set, desc: "set configuration variable(s)",
                         type: :array, default: []
            def check(app_dir = nil, *extra_files)
                app = Roby.app
                app.app_dir = app_dir if app_dir
                app.require_app_dir
                app.setup_robot_names_from_config_dir
                app.robot(*options[:robot].split(","))

                options[:set].each do |v|
                    app.argv_set << v
                    Roby::Application.apply_conf_from_argv(v)
                end

                begin
                    app.setup
                    extra_files.each do |path|
                        app.require(File.expand_path(path))
                    end
                ensure app.cleanup
                end
            end

            desc "console", "open a pry console after the app code has been loaded"
            option :robot, aliases: "r", default: "default",
                           desc: "the robot name, separate name and type a comma"
            def console(*extra_files)
                require "pry"
                app = Roby.app
                app.require_app_dir
                app.setup_robot_names_from_config_dir
                app.robot(*options[:robot].split(","))
                begin
                    app.setup
                    extra_files.each do |path|
                        app.require(File.expand_path(path))
                    end
                    pry
                ensure
                    app.cleanup
                end
            end
        end
    end
end
