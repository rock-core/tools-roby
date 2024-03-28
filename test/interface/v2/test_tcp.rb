# frozen_string_literal: true

require "roby/test/self"
require "roby/interface/v2/tcp"

module Roby
    module Interface
        module V2
            describe TCPServer do
                before do
                    @tcp_test_app = Application.new
                    @server = TCPServer.new(@tcp_test_app, port: 0)
                    @clients = {}
                end

                after do
                    @server.close
                    @clients.each_value(&:close)
                end

                def expect_execution(plan: @tcp_test_app.plan, &block)
                    super(plan: plan, &block)
                end

                def connect
                    socket = TCPSocket.new("localhost", @server.ip_port)
                    current_client_count = @server.clients.size
                    while current_client_count == @server.clients.size
                        @server.process_pending_requests
                        Thread.pass
                    end

                    roby_client = @server.clients.last
                    @clients[roby_client] = socket
                    roby_client
                end

                describe "error handling" do
                    before do
                        flexmock(@client = connect)
                        flexmock(Roby).should_receive(:log_exception_with_backtrace)
                            .by_default
                    end

                    def self.common_behavior_on_poll_exception
                        it "does not disconnect a client based on the return value of #poll" do
                            @client.should_receive(:poll).and_return(true)
                            @server.process_pending_requests
                            refute @client.closed?
                            assert @server.has_client?(@client)
                        end
                        it "disconnects a client that raises within #poll" do
                            @client.should_receive(:poll).and_raise(ComError)
                            @server.process_pending_requests
                            assert @client.closed?
                            refute @server.has_client?(@client)
                        end
                        it "processes other clients after a ComError" do
                            other_client = connect
                            @client.should_receive(:poll).and_raise(ComError)
                            flexmock(other_client).should_receive(:poll).once
                            @server.process_pending_requests
                        end
                    end

                    describe "abort_on_exception?: true" do
                        before do
                            @server.abort_on_exception = true
                        end

                        common_behavior_on_poll_exception

                        it "registers a non-ComError exception as a framework error" do
                            @client.should_receive(:poll).and_raise(RuntimeError)
                            expect_execution { @server.process_pending_requests }
                                .to { have_framework_error_matching RuntimeError }
                        end
                    end

                    describe "abort_on_exception?: false" do
                        before do
                            @server.abort_on_exception = false
                        end

                        common_behavior_on_poll_exception

                        it "displays an exception that is not ComError" do
                            @client.should_receive(:poll).and_raise(RuntimeError)
                            flexmock(Roby).should_receive(:log_exception_with_backtrace)
                                .with(RuntimeError, Roby::Interface, :warn)
                                .once
                            @server.process_pending_requests
                        end
                        it "processes other clients after an exception that is not ComError" do
                            other_client = connect
                            @client.should_receive(:poll).and_raise(RuntimeError)
                            flexmock(other_client).should_receive(:poll).once
                            @server.process_pending_requests
                        end
                    end
                end
            end
        end
    end
end
