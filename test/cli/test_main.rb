require 'roby/test/self'
require 'roby/cli/main'
require 'roby/interface/rest'
require 'roby/test/aruba_minitest'

module Roby
    module CLI
        describe Main do
            include Roby::Test::ArubaMinitest

            describe "run" do
                before do
                    run_command "roby gen app"
                end

                after do
                    FileUtils.rm_f "/tmp/roby-cli-main-rest-test"
                end

                def wait_for_file(path)
                    assert_eventually { File.exist?(path) }
                end

                def assert_eventually(timeout: 10, msg: "failed while waiting for something to happen")
                    deadline = Time.now + timeout
                    while true
                        if yield
                            return
                        elsif deadline < Time.now
                            flunk(msg)
                        end
                        sleep 0.05
                    end
                end

                describe "the REST API" do
                    it "starts the API on the default port if --rest is given" do
                        run_command "roby run --rest"
                        assert_eventually { Interface::REST::Server.server_alive?(
                            'localhost', Interface::DEFAULT_REST_PORT) }
                        run_command_and_stop "roby quit --retry"
                    end
                    it "starts the API on a custom port if an integer argument is given to --rest" do
                        # Guess an available port ... not optimal, but hopefully good enough
                        tcp_server = TCPServer.new(0)
                        port = tcp_server.local_address.ip_port
                        tcp_server.close
                        run_command "roby run --rest=#{port}"
                        assert_eventually { Interface::REST::Server.server_alive?(
                            'localhost', port) }
                        run_command_and_stop "roby quit --retry"
                    end
                    it "properly shuts down the server" do
                        # We check whether the server gets shut down by
                        # starting two apps one after the other. If the socket
                        # is not closed, we won't be able to create the new
                        # server
                        @run_cmd = run_command "roby run --rest"
                        run_command_and_stop "roby quit --retry"
                        assert_command_stops @run_cmd
                        @run_cmd = run_command "roby run --rest"
                        run_command_and_stop "roby quit --retry"
                        assert_command_stops @run_cmd
                    end
                    it "starts the API on a Unix socket if one is given" do
                        dir = make_tmpdir
                        socket = File.join(dir, "rest-socket")
                        run_command "roby run --rest=#{socket}"
                        assert_eventually { File.exist?(socket) }
                        run_command_and_stop "roby quit --retry"
                    end
                end
            end

            describe "quit" do
                before do
                    run_command_and_stop "roby gen app"
                end
                it "exits with a nonzero status if there is no app to quit" do
                    cmd = run_command "roby quit"
                    cmd.stop
                    assert_equal 1, cmd.exit_status
                end
                it "stops a running app" do
                    run_cmd = run_command "roby run"
                    run_command_and_stop "roby wait"
                    run_command_and_stop "roby quit"
                    assert_command_stops run_cmd
                end
                it "stops a running app on another port" do
                    run_cmd = run_command "roby run --port 9999"
                    run_command_and_stop "roby wait --host localhost:9999"
                    run_command_and_stop "roby quit --host localhost:9999"
                    assert_command_stops run_cmd
                end
                it "waits forever for the app to be available if --retry is given" do
                    run_cmd = run_command "roby run"
                    run_command_and_stop "roby quit --retry"
                    assert_command_stops run_cmd
                end
                it "times out on retrying if --retry is given a timeout" do
                    before = Time.now
                    cmd = run_command "roby quit --retry=1"
                    cmd.stop
                    assert_equal 1, cmd.exit_status
                    assert (Time.now - before) > 1
                end
            end
        end
    end
end
