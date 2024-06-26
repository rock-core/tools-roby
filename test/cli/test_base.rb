# frozen_string_literal: true

require "roby/test/self"
require "roby/cli/base"
require "roby/test/roby_app_helpers"

module Roby
    module CLI
        describe Base do
            include Test::RobyAppHelpers

            describe "parse_host_option" do
                before do
                    @cli = Base.new
                    @options = {}
                    flexmock(@cli).should_receive(:options).and_return { @options }
                end

                it "parses the host option" do
                    @options[:host] = "localhost:1234"
                    assert_equal({ host: "localhost", port: 1234 },
                                 @cli.parse_host_option)
                end

                it "resolves the vagrant VM name" do
                    @options[:vagrant] = "localhost:1234"
                    flexmock(Roby::App::Vagrant)
                        .should_receive(:resolve_ip)
                        .with("localhost").and_return("abcd")
                    assert_equal({ host: "abcd", port: 1234 },
                                 @cli.parse_host_option)
                end

                it "returns an empty hash if neither vagrant nor host are set" do
                    assert_equal({}, @cli.parse_host_option)
                end

                it "raises if both options are set" do
                    @options[:host] = "localhost:1234"
                    @options[:vagrant] = "localhost:1234"
                    assert_raises(ArgumentError) do
                        @cli.parse_host_option
                    end
                end
            end

            describe "setup_roby_for_running" do
                it "configures the process to run an app without controller blocks" do
                    dir = roby_app_setup_single_script("cli_base.rb")
                    script_path = File.join(dir, "scripts", "cli_base.rb")
                    port = roby_app_allocate_interface_port
                    pid = spawn(Gem.ruby, script_path, "cmd", "--controllers=f",
                                "--log=robot:FATAL", "--port=#{port}", chdir: dir)
                    register_pid(pid)
                    assert_roby_app_quits(pid, port: port)
                    refute File.exist?(File.join(dir, "created_by_controller"))
                end

                it "configures the process to run an app with controller blocks" do
                    dir = roby_app_setup_single_script("cli_base.rb")
                    script_path = File.join(dir, "scripts", "cli_base.rb")
                    port = roby_app_allocate_interface_port
                    pid = spawn(Gem.ruby, script_path, "cmd", "--controllers=t",
                                "--log=robot:FATAL", "--port=#{port}", chdir: dir)
                    register_pid(pid)
                    assert_eventually do
                        File.exist?(File.join(dir, "created_by_controller"))
                    end
                    assert_roby_app_quits(pid, port: port)
                end

                it "handles the robot option" do
                    dir = roby_app_setup_single_script("cli_base.rb")
                    File.open(File.join(dir, "config", "robots", "test.rb"), "w") do |io|
                        io.puts <<~ROBOT
                            Robot.controller do
                                FileUtils.touch(File.join(
                                    Roby.app.app_dir, 'created_by_test_controller'
                                ))
                            end
                        ROBOT
                    end
                    script_path = File.join(dir, "scripts", "cli_base.rb")
                    port = roby_app_allocate_interface_port
                    pid = spawn(Gem.ruby, script_path, "cmd",
                                "--log=robot:FATAL",
                                "--robot=test", "--controllers=t", "--port=#{port}",
                                chdir: dir)
                    register_pid(pid)
                    assert_eventually do
                        File.exist?(File.join(dir, "created_by_test_controller"))
                    end
                    assert_roby_app_quits(pid, port: port)
                end
            end

            describe "#setup_roby_for_interface" do
                it "connects to a running app" do
                    gen_app
                    port = roby_app_allocate_interface_port
                    pid = roby_app_spawn("run", "--log=robot:FATAL", port: port)
                    assert_roby_app_is_running pid, port: port

                    interface = Base.new([], { host: "localhost:#{port}" })
                                    .setup_roby_for_interface(app: app)
                    assert_kind_of Interface::V1::Client, interface
                    assert_roby_app_quits(pid, interface: interface)
                end

                it "retries connection if there is nothing to connect to" do
                    flexmock(Robot)
                        .should_receive(:warn)
                        .with(/failed\sto\sconnect.*(?:
                               Connection\srefused|
                               Cannot\sassign\srequested\saddress)/x)
                        .at_least.once
                    gen_app
                    port = roby_app_allocate_interface_port
                    t = Thread.new do
                        Base.new([], { host: "localhost:#{port}" })
                            .setup_roby_for_interface(
                                app: app, retry_connection: true, timeout: 5,
                                retry_period: 0.5
                            )
                    end
                    pid = roby_app_spawn("run", "--log=robot:FATAL", port: port)
                    interface = t.value
                    assert_kind_of Interface::V1::Client, interface
                    # Do not reuse `interface`. It has been used in a different
                    # thread and Roby has protections against cross-thread use
                    assert_roby_app_quits(pid, port: port)
                end

                describe "if there is nothing to connect to" do
                    it "raises right away if retry_connection is false" do
                        gen_app
                        port = roby_app_allocate_interface_port
                        assert_raises(RuntimeError) do
                            Base.new([], { host: "localhost:#{port}" })
                                .setup_roby_for_interface(app: app)
                        end
                    end

                    it "retries and then fails if retry_connection is set and "\
                       "there is a timeout" do
                        flexmock(Robot)
                            .should_receive(:warn)
                            .with(/failed\sto\sconnect.*(?:
                                   Connection\srefused|
                                   Cannot\sassign\srequested\saddress)/x)
                            .at_least.once
                        gen_app
                        port = roby_app_allocate_interface_port
                        tic = Time.now
                        e = assert_raises(Roby::Interface::ConnectionError) do
                            Base.new([], { host: "localhost:#{port}" })
                                .setup_roby_for_interface(
                                    app: app, retry_connection: true, timeout: 2,
                                    retry_period: 1
                                )
                        end
                        assert_operator Time.now - tic, :>, 1.5,
                                        "#{e} received after #{Time.now - tic} "\
                                        "seconds, expected a timeout of 2s"
                    end
                end
            end

            def assert_eventually(timeout: 10)
                deadline = Time.now + timeout
                loop do
                    if Time.now > deadline
                        flunk("did not reach the expected condition in #{timeout}s")
                    end

                    break if yield
                end
            end
        end
    end
end
