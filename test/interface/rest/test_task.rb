# frozen_string_literal: true

require "roby/test/self"
require "roby/interface/rest/task"
require "roby/interface/rest/server"

module Roby
    module Interface
        module REST
            describe Task do
                attr_reader :rest_task

                before do
                    @rest_task = Task.new(host: "127.0.0.1", port: 0)
                    plan.add(rest_task)

                    expect_execution { rest_task.start! }.to { emit rest_task.start_event }
                end

                it "starts a webserver with our API on start" do
                    assert Server.server_alive?(
                        "127.0.0.1", rest_task.actual_port)
                end

                it "shuts down the server on stop" do
                    expect_execution { rest_task.stop! }.to { emit rest_task.stop_event }
                    refute Server.server_alive?(
                        "127.0.0.1", rest_task.actual_port)
                end

                it "can be configured with a different mounting point" do
                    @rest_task = Task.new(host: "127.0.0.1", port: 0, main_route: "/root")
                    plan.add(rest_task)
                    expect_execution { rest_task.start! }
                        .to { emit rest_task.start_event }

                    assert Server.server_alive?(
                        "127.0.0.1", rest_task.actual_port, main_route: "/root")
                    assert_raises(REST::Server::InvalidServer) do
                        Server.server_alive?(
                            "127.0.0.1", rest_task.actual_port, main_route: "/api")
                    end
                end

                describe "#url_for" do
                    it "returns the full URL to an API path" do
                        rest_task = Task.new(host: "127.0.0.1", port: 0,
                                             main_route: "/root")
                        plan.add(rest_task)
                        expect_execution { rest_task.start! }
                            .to { emit rest_task.start_event }
                        actual_port = rest_task.actual_port
                        assert_equal "http://some_host:#{actual_port}/root/sub/path",
                                     rest_task.url_for("sub/path", host: "some_host")
                    end
                end
            end
        end
    end
end
