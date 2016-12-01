require 'roby'
require 'thor'
require 'roby/droby/logfile/server'
require 'roby/droby/logfile/client'
require 'roby/interface'

module Roby
    module CLI
        class Display < Thor
            Server = Roby::DRoby::Logfile::Server

            default_command 'backward'

            class_option :debug, type: :boolean, default: false
            class_option :config, type: :string, default: nil,
                desc: 'path to the roby-display configuration file'

            desc 'backward', 'backward-compatible interface with the old roby-display'
            option :client, type: :string, lazy_default: "localhost:#{Interface::DEFAULT_PORT}"
            option :host, type: :string, lazy_default: "localhost:#{Interface::DEFAULT_PORT}"
            option :vagrant, type: :string, default: nil
            option :server, type: :numeric
            option :sampling, type: :numeric
            def backward(*path)
                host, port = 'localhost', Server::DEFAULT_PORT
                if remote_addr = (options[:client] || options[:host])
                    if options[:host]
                        Roby.warn_deprecated "--host is deprecated, use 'roby-display client' instead, run roby-display help for more information"
                    else
                        Roby.warn_deprecated "roby-display --client=HOST is now roby-display client HOST, run roby-display help for more information"
                    end
                    if vagrant_host = options[:vagrant]
                        _, port = remote_addr.split(':')
                        remote_addr = "vagrant:#{vagrant_host}:#{port}"
                    end
                    client(remote_addr)
                elsif bind_port = options[:server]
                    Roby.warn_deprecated "roby-display --server PATH is now roby-display server PATH, run roby-display help for more information"
                    server(*path, port: bind_port)
                else
                    file(*path)
                end
            end

            desc 'file PATH', 'inspect an existing log file'
            option :display, type: :string, desc: 'a display to open right away (relations, chronicle or all)'
            def file(path)
                apply_common_options

                with_display do |app, display|
                    display.open(path)
                end
            end

            desc 'client HOST[:PORT]', 'connect to a running Roby instance'
            option :display, type: :string, desc: 'a display to open right away (relations, chronicle or all)'
            def client(remote_addr)
                apply_common_options

                host, port = resolve_remote_host(remote_addr)
                with_display do |app, display|
                    display.connect(host, port: port)
                end
            end

            desc 'server PATH', "serve the given log file"
            option :fd, desc: 'the file descriptor of the TCP server socket',
                type: :numeric
            option :port, desc: 'port number on which to create the server',
                type: :numeric, default: Server::DEFAULT_PORT
            option :sampling, type: :numeric,
                default: Server::DEFAULT_SAMPLING_PERIOD,
                desc: 'period in seconds at which the server should poll the log file'
            def server(path, port: options[:port])
                # NOTE: the 'port' argument is here so that it can be overriden
                # in {#backward}
                apply_common_options

                if server_fd = options[:fd]
                    server_io = TCPServer.for_fd(server_fd)
                else
                    server_io =
                        begin TCPServer.new(port)
                        rescue TypeError # Workaround for https://bugs.ruby-lang.org/issues/10203
                            raise Errno::EADDRINUSE, "Address already in use - bind(2) for \"0.0.0.0\" port #{port}"
                        end
                end

                server = Roby::DRoby::Logfile::Server.new(path, options[:sampling], server_io)
                port = server_io.local_address.ip_port
                Server.info "Roby log server listening on port #{port}, sampling period=#{options[:sampling]}"
                Server.info "watching #{path}"
                server.exec
            ensure
                server_io.close if server_io
            end

            attr_reader :config_path

            no_commands do
                def apply_common_options
                    if options[:debug]
                        Server.logger.level = Logger::DEBUG
                        Roby::DRoby::Logfile.logger.level = Logger::DEBUG
                    end

                    if config_path = options[:config]
                        @config_path = File.expand_path(config_path)
                    elsif Roby.app.app_dir
                        @config_path = Roby.app.find_file('config', 'roby-display.yml', order: :specific_first) ||
                            File.join(Roby.app.app_dir, "config", "roby-display.yml")
                    end
                end

                def discover_log_server_port(host, interface_port)
                    client = Interface.connect_with_tcp_to(host, interface_port)
                    port = client.log_server_port
                ensure
                    client.close if client
                end

                def resolve_remote_host(host_spec = '')
                    parts = host_spec.split(':')
                    if parts[0] == 'vagrant'
                        vagrant_id = parts[1]
                        if !vagrant_id
                            raise ArgumentError, "expected vagrant: to be followed by the ID of a vagrant VM"
                        end
                        require 'roby/app/vagrant'
                        host = Roby::App::Vagrant.resolve_ip(vagrant_id)
                        port = parts[2]
                    else
                        host, port = *parts
                        host = 'localhost' if !host || host.empty?
                    end
                    port = Interface::DEFAULT_PORT.to_s if !port

                    if port[0, 1] != '!'
                        port = discover_log_server_port(host, Integer(port) || Interface::DEFAULT_PORT)
                    else
                        port = Integer(port[1..-1] || Server::DEFAULT_PORT)
                    end
                    return host, port
                end

                def with_display
                    require 'Qt'
                    require 'roby/droby/logfile/reader'
                    require 'roby/droby/plan_rebuilder'
                    require 'roby/gui/log_display'

                    app = Qt::Application.new(ARGV)

                    display = Roby::GUI::LogDisplay.new
                    if display_mode = options[:display]
                        if display_mode == 'all'
                            display.create_all_displays
                        else
                            display.create_display(display_mode)
                        end
                    end

                    if config_path
                        apply_config(display, config_path)
                    end
                    yield(app, display)
                    display.show
                    app.exec
                ensure
                    if config_path
                        save_config(display, config_path)
                    end
                end

                def apply_config(display, config_path)
                    if File.file?(config_path)
                        display.load_options(config_path)
                    end
                end
                def save_config(display, config_path)
                    FileUtils.mkdir_p(File.dirname(config_path))
                    File.open(config_path, 'w') do |io|
                        YAML.dump(display.save_options, io)
                    end
                end
            end
        end
    end
end

