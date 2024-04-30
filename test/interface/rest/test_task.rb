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

                    expect_execution { rest_task.start! }
                        .to { emit rest_task.start_event }
                end

                it "starts a webserver with our API on start" do
                    assert Server.server_alive?(
                        "127.0.0.1", rest_task.actual_port
                    )
                end

                it "shuts down the server on stop" do
                    expect_execution { rest_task.stop! }.to { emit rest_task.stop_event }
                    refute Server.server_alive?(
                        "127.0.0.1", rest_task.actual_port
                    )
                end

                it "can be configured with a different mounting point" do
                    @rest_task = Task.new(host: "127.0.0.1", port: 0, main_route: "/root")
                    plan.add(rest_task)
                    expect_execution { rest_task.start! }
                        .to { emit rest_task.start_event }

                    assert Server.server_alive?(
                        "127.0.0.1", rest_task.actual_port, main_route: "/root"
                    )
                    assert_raises(REST::Server::InvalidServer) do
                        Server.server_alive?(
                            "127.0.0.1", rest_task.actual_port, main_route: "/api"
                        )
                    end
                end

                describe "default middlewares" do
                    before do
                        api = Class.new(Grape::API) do
                            format :json

                            mount API
                            get "fail" do
                                raise "some error"
                            end
                        end
                        @task_m = Task.new_submodel { define_method(:rest_api) { api } }
                    end

                    it "does not install reporting middlewares if verbose is false" do
                        plan.add(task = @task_m.new(port: 0, verbose: false))
                        expect_execution { task.start! }.to { emit task.start_event }

                        _, err = capture_subprocess_io do
                            assert_raises(RestClient::InternalServerError) do
                                RestClient.get(
                                    "http://127.0.0.1:#{task.actual_port}/api/fail"
                                )
                            end
                        end
                        assert_equal "", err
                    end

                    it "installs both the logger and error reporting middlewares if "\
                       "verbose is true" do
                        plan.add(task = @task_m.new(port: 0, verbose: true))
                        expect_execution { task.start! }.to { emit task.start_event }

                        _, err = capture_subprocess_io do
                            assert_raises(RestClient::InternalServerError) do
                                RestClient.get(
                                    "http://127.0.0.1:#{task.actual_port}/api/fail"
                                )
                            end
                        end
                        assert_match(/some error/, err)
                        assert_match(%r{GET /api/fail.*500}m, err)
                    end
                end

                it "uses the return value from rest_server_args to compute the args" do
                    api = Class.new(Grape::API) do
                        mount API
                        helpers Helpers

                        get "/storage_value" do
                            roby_storage[:test_storage_value]
                        end
                    end
                    task_m = Task.new_submodel do
                        define_method(:rest_api) { api }
                        def rest_server_args
                            super.merge(
                                storage: { test_storage_value: 10 }
                            )
                        end
                    end

                    plan.add(task = task_m.new(port: 0))
                    expect_execution { task.start! }.to { emit task.start_event }

                    assert_equal "10", RestClient.get(
                        "http://127.0.0.1:#{task.actual_port}/api/storage_value"
                    )
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
