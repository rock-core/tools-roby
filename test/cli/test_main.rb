# frozen_string_literal: true

require "roby/test/self"
require "roby/cli/main"
require "roby/interface/rest"
require "roby/test/aruba_minitest"

module Roby
    module CLI
        describe Main do
            include Roby::Test::ArubaMinitest

            describe "run" do
                before do
                    run_roby_and_stop "gen app"
                end

                def wait_for_file(path)
                    assert_eventually { File.exist?(path) }
                end

                def assert_eventually(
                    timeout: 10, msg: "failed while waiting for something to happen"
                )
                    deadline = Time.now + timeout
                    loop do
                        if yield
                            return
                        elsif deadline < Time.now
                            flunk(msg)
                        end

                        sleep 0.05
                    end
                end

                describe "the REST API" do
                    before do
                        @interface_port = roby_allocate_port
                        @rest_port = roby_allocate_port
                    end

                    it "starts the API" do
                        # Guess an available port ... not optimal, but hopefully good enough
                        run_roby "run --rest=#{@rest_port} --port=#{@interface_port}"
                        assert_eventually do
                            Interface::REST::Server.server_alive?(
                                "localhost", @rest_port
                            )
                        end
                        run_roby_and_stop "quit --retry --host=localhost:#{@interface_port}"
                    end
                    it "properly shuts down the server" do
                        # We check whether the server gets shut down by
                        # starting two apps one after the other. If the socket
                        # is not closed, we won't be able to create the new
                        # server
                        @run_cmd = run_roby "run --rest=#{@rest_port} --port=#{@interface_port}"
                        run_roby_and_stop "quit --retry --host=localhost:#{@interface_port}"
                        assert_command_stops @run_cmd
                        @run_cmd = run_roby "run --rest=#{@rest_port} --port=#{@interface_port}"
                        run_roby_and_stop "quit --retry --host=localhost:#{@interface_port}"
                        assert_command_stops @run_cmd
                    end
                    it "starts the API on a Unix socket if one is given" do
                        dir = make_tmpdir
                        socket = File.join(dir, "rest-socket")
                        run_roby "run --rest=#{socket} --port=#{@interface_port}"
                        assert_eventually { File.exist?(socket) }
                        run_roby_and_stop "quit --retry --host=localhost:#{@interface_port}"
                    end
                end
            end

            describe "quit" do
                before do
                    run_roby_and_stop "gen app"
                    @interface_port = roby_allocate_port
                end
                it "exits with a nonzero status if there is no app to quit" do
                    cmd = run_roby "quit --host=localhost:#{@interface_port}"
                    cmd.stop
                    assert_equal 1, cmd.exit_status
                end
                it "stops a running app" do
                    run_cmd = run_roby "run --port=#{@interface_port}"
                    run_roby_and_stop "wait --host=localhost:#{@interface_port}"
                    run_roby_and_stop "quit --host=localhost:#{@interface_port}"
                    assert_command_stops run_cmd
                end
                it "waits forever for the app to be available if --retry is given" do
                    run_cmd = run_roby "run --port=#{@interface_port}"
                    run_roby_and_stop "quit --retry --host=localhost:#{@interface_port}"
                    assert_command_stops run_cmd
                end
                it "times out on retrying if --retry is given a timeout" do
                    before = Time.now
                    cmd = run_roby "quit --retry=1 --host=localhost:#{@interface_port}"
                    cmd.stop
                    assert_equal 1, cmd.exit_status
                    assert (Time.now - before) > 1
                end
            end

            describe "shell" do
                before do
                    run_roby_and_stop "gen app"
                    @interface_port = roby_allocate_port
                end
                it "connects and sends commands" do
                    run_cmd = run_roby "run --port #{@interface_port}"
                    shell_cmd = run_roby "shell --host localhost:#{@interface_port}"
                    shell_cmd.write "quit\n"
                    shell_cmd.write "exit\n"
                    assert_command_stops shell_cmd
                    assert_command_stops run_cmd
                end
            end
        end
    end
end
