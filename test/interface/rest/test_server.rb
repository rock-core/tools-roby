# frozen_string_literal: true

require "roby/test/self"
require "roby/interface/rest"

module Roby
    module Interface
        module REST
            describe Server do
                after do
                    if @server&.running?
                        @server.wait_start
                        @server.stop
                    end

                    EventMachine.stop if EventMachine.reactor_running?
                end

                describe "#running?" do
                    before do
                        @server = REST::Server.new(app, port: 0)
                    end
                    it "returns false before the call to #start" do
                        refute @server.running?
                    end
                    it "returns true just after #start" do
                        @server.start(wait_timeout: 0)
                        assert @server.running?
                    end
                    it "returns false after being stopped and joined" do
                        @server.start(wait_timeout: 0)
                        @server.stop
                        refute @server.running?
                    end
                end

                describe "the start timeout behavior" do
                    it "does not wait at all if the start timeout is zero" do
                        @server = REST::Server.new(app, port: 0)
                        flexmock(@server).should_receive(:wait_start).never
                        @server.start(wait_timeout: 0)
                    end

                    it "raises if the thread is not functional after "\
                       "the alloted timeout" do
                        @server = REST::Server.new(app, port: 0)
                        flexmock(@server).should_receive(:create_thin_thread)
                                         .and_return { Thread.new {} }
                        assert_raises(REST::Server::Timeout) do
                            @server.start(wait_timeout: 0.01)
                        end
                        @server.stop
                    end
                end

                it "makes available the storage argument as roby_storage in the API" do
                    api = Class.new(Grape::API) do
                        mount API
                        helpers Helpers

                        get "/storage_value" do
                            roby_storage[:test_storage_value]
                        end
                    end
                    storage = { test_storage_value: 10 }
                    @server = REST::Server.new(app, api: api, storage: storage, port: 0)
                    @server.start

                    assert_equal "10", get(
                        "http://127.0.0.1:#{@server.port}/api/storage_value"
                    )
                end

                it "synchronizes calls with the underlying execution engine" do
                    call_thread = nil
                    api = Class.new(Grape::API) do
                        mount API

                        get "/sync_test" do
                            call_thread = Thread.current
                            nil
                        end
                    end
                    @server = REST::Server.new(app, api: api, port: 0)
                    @server.start

                    get "http://127.0.0.1:#{@server.port}/api/sync_test"
                    assert_equal Thread.current, call_thread
                end

                it "allows that endpoints call roby_execute" do
                    call_thread = nil
                    api = Class.new(Grape::API) do
                        mount API
                        helpers Helpers

                        get "/sync_test" do
                            roby_execute do
                                call_thread = Thread.current
                            end
                            nil
                        end
                    end
                    @server = REST::Server.new(app, api: api, port: 0)
                    @server.start

                    get("http://127.0.0.1:#{@server.port}/api/sync_test")
                    assert_equal Thread.current, call_thread
                end

                it "allows to disable synchronization with the engine" do
                    call_thread = nil
                    api = Class.new(Grape::API) do
                        mount API

                        get "/sync_test" do
                            call_thread = Thread.current
                            nil
                        end
                    end
                    @server = REST::Server.new(
                        app, api: api, port: 0, roby_execute: false
                    )
                    @server.start

                    get "http://127.0.0.1:#{@server.port}/api/sync_test"
                    refute_equal Thread.current, call_thread
                end

                describe "over TCP" do
                    describe "a given port of zero" do
                        before do
                            @server = REST::Server.new(app, port: 0, roby_execute: false)
                        end

                        it "spawns a working server and waits for it to be functional" do
                            @server.start
                            assert @server.server_alive?
                        end

                        describe "#port" do
                            it "returns the port right away if the server is started "\
                               "and synchronized" do
                                @server.start
                                refute_equal 0, @server.port(timeout: 0)
                            end
                            it "waits for the port to be available "\
                               "if the server is started" do
                                @server.start(wait_timeout: 0)
                                refute_equal 0, @server.port(timeout: 1)
                            end
                            it "times out if the server is not yet started" do
                                assert_raises(REST::Server::Timeout) do
                                    @server.port
                                end
                            end
                            it "returns the actual port if the server has been started "\
                               "and then stopped" do
                                @server.start
                                @server.stop
                                refute_equal 0, @server.port
                            end
                        end
                    end

                    describe "a nonzero port" do
                        before do
                            server = ::TCPServer.new(0)
                            @port = server.local_address.ip_port
                            server.close
                            @server = REST::Server.new(
                                app, port: @port, roby_execute: false
                            )
                        end

                        it "spawns a working server and waits for it to be functional" do
                            @server.start
                            assert @server.server_alive?
                        end

                        describe "#port" do
                            it "returns the port if the server is not yet started" do
                                assert_equal @port, @server.port
                            end

                            it "returns the port if the server is started but we did "\
                               "not synchronize" do
                                @server.start(wait_timeout: 0)
                                assert_equal @port, @server.port
                            end

                            it "returns the port if the server is started "\
                               "and synchronized" do
                                @server.start
                                assert_equal @port, @server.port
                            end

                            it "returns the port if the server is started and stopped" do
                                @server.start
                                @server.stop
                                assert_equal @port, @server.port
                            end
                        end
                    end
                end

                def get(*args)
                    execute_promise { RestClient.get(*args) }
                end

                def execute_promise(&block)
                    promise = execution_engine.promise(&block)
                    execute { promise.execute }
                    promise.value!
                end
            end
        end
    end
end
