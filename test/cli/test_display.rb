require 'roby/test/self'
require 'roby/cli/display'
require 'roby/test/roby_app_helpers'

module Roby
    module CLI
        describe Display do
            describe "backward-compatible behaviour" do
                def create_cli(args = [], **options)
                    cli = CLI::Display.new(args, options)
                    flexmock(cli)
                    cli
                end

                describe "--client" do
                    before do
                        flexmock(Roby).should_receive(:warn_deprecated).
                            with('roby-display --client=HOST is now roby-display client HOST, run roby-display help for more information').
                            once
                    end

                    it "calls the 'client' command" do
                        cli = create_cli(client: 'host:port')
                        cli.should_receive(:client).with('host:port').once
                        cli.backward
                    end
                    it "passes the argument to --vagrant into the remote address" do
                        cli = create_cli(vagrant: 'vagrant_id', client: ':port')
                        cli.should_receive(:client).with('vagrant:vagrant_id:port').once
                        cli.backward
                    end
                end
                describe "--host" do
                    it "calls the 'client' command" do
                        cli = CLI::Display.new([], Hash[host: 'host:port'])
                        flexmock(Roby).should_receive(:warn_deprecated).
                            with("--host is deprecated, use 'roby-display client' instead, run roby-display help for more information").
                            once
                        flexmock(cli).should_receive(:client).with('host:port').once
                        cli.backward
                    end
                end
                describe '--server' do
                    before do
                        flexmock(Roby).should_receive(:warn_deprecated).
                            with('roby-display --server PATH is now roby-display server PATH, run roby-display help for more information').
                            once
                    end
                    it "calls the 'server' command" do
                        cli = create_cli(server: 'port')
                        cli.should_receive(:server).with('/path/to/file', port: 'port').once
                        cli.backward('/path/to/file')
                    end
                end
            end
            describe "#server" do
                include Test::RobyAppHelpers

                attr_reader :logfile_path
                before do
                    @logfile_path, writer = roby_app_create_logfile
                    writer.close
                end
                after do
                    if @__display_thread
                        if @__display_thread.respond_to?(:report_on_exception=)
                            @__display_thread.report_on_exception = false
                        end
                        @__display_thread.raise Interrupt
                        @__display_thread.join
                    end
                end
                def start_log_server_thread(*args)
                    @__display_thread = Thread.new { yield }
                end

                it "starts a log server on the default server port" do
                    start_log_server_thread { Display.start(['server', logfile_path]) }
                    assert_roby_app_can_connect_to_log_server(
                        port: Roby::DRoby::Logfile::Server::DEFAULT_PORT)
                end
                it "works around https://bugs.ruby-lang.org/issues/10203" do
                    flexmock(TCPServer).should_receive(:new).and_raise(TypeError)
                    assert_raises(Errno::EADDRINUSE) do
                        Display.start(['server', logfile_path])
                    end
                end
                it "allows to override the port to a non-default one via the command line" do
                    start_log_server_thread do
                        Display.start(['server', logfile_path, "--port=20250"])
                    end
                    assert_roby_app_can_connect_to_log_server(port: 20250)
                end
                it "allows to override the port to a non-default one via method call" do
                    # Needed by #backward
                    start_log_server_thread do
                        cli = Display.new
                        cli.server(logfile_path, port: 20250)
                    end
                    assert_roby_app_can_connect_to_log_server(port: 20250)
                end
                it "can take over a server socket given with --fd" do
                    socket = TCPServer.new(0)
                    start_log_server_thread do
                        Display.start(['server', logfile_path, "--fd=#{socket.fileno}"])
                    end
                    assert_roby_app_can_connect_to_log_server(
                        port: socket.local_address.ip_port)
                end
            end
            describe "#parse_remote_host" do
                include Test::RobyAppHelpers

                attr_reader :logfile_path, :cli
                before do
                    @logfile_path, writer = roby_app_create_logfile
                    writer.close
                    @cli = CLI::Display.new
                end
                it "uses a direct host and port syntax" do
                    assert_equal ['host', 2356], cli.resolve_remote_host('host:!2356')
                end
                it "uses localhost as host by default" do
                    assert_equal ['localhost', 2356], cli.resolve_remote_host(':!2356')
                end
                it "resolves the port by contacting the Roby instance" do
                    app.setup_shell_interface
                    app.start_log_server(logfile_path, 'silent' => true)
                    resolve_thread = Thread.new { cli.resolve_remote_host }
                    capture_subprocess_io do
                        while resolve_thread.alive?
                            app.shell_interface.process_pending_requests
                        end
                    end
                    assert_roby_app_can_connect_to_log_server
                    assert_equal ['localhost', app.log_server_port], resolve_thread.value
                end
                it "resolves vagrant:ID into the corresponding vagrant IP" do
                    require 'roby/app/vagrant'
                    flexmock(Roby::App::Vagrant).should_receive(:resolve_ip).
                        with('vagrantid').once.
                        and_return('resolved_host')
                    assert_equal ['resolved_host', 2356],
                        cli.resolve_remote_host('vagrant:vagrantid:!2356')
                end
                it "uses the default shell port with a vagrant ID if none is provided" do
                    flexmock(cli).should_receive(:discover_log_server_port).
                        with('resolved_host', Interface::DEFAULT_PORT).
                        once.and_return(2356)
                    require 'roby/app/vagrant'
                    flexmock(Roby::App::Vagrant).should_receive(:resolve_ip).
                        with('vagrantid').once.
                        and_return('resolved_host')
                    assert_equal ['resolved_host', 2356],
                        cli.resolve_remote_host('vagrant:vagrantid')
                end
                it "raises if 'vagrant' or 'vagrant:' are given" do
                    assert_raises(ArgumentError) do
                        cli.resolve_remote_host('vagrant')
                    end
                    assert_raises(ArgumentError) do
                        cli.resolve_remote_host('vagrant:')
                    end
                end
            end
        end
    end
end

