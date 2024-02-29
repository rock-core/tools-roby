# frozen_string_literal: true

require "roby/test/self"
require "socket"
require "roby/interface/shell_client"
require "roby/interface/tcp"

module Roby
    module Interface
        describe ShellClient do
            before do
                @app = Roby::Application.new
                @plan = @app.plan
                register_plan(@plan)

                @interface = flexmock(Interface.new(@app))

                server_socket, @client_socket = Socket.pair(:UNIX, :DGRAM, 0)
                @server_channel = Channel.new(server_socket, false)
                @server = Server.new(@server_channel, @interface)
            end

            def with_polling_server(&block)
                @server_channel.reset_thread_guard
                quit = Concurrent::Event.new
                poller = Thread.new do
                    until quit.set?
                        @server.poll
                        sleep 0.01
                    end
                end
                result = yield
                quit.set
                poller.join
                @server_channel.reset_thread_guard
                result
            end

            let :shell_client do
                with_polling_server do
                    ShellClient.new "remote" do
                        Client.new(Channel.new(@client_socket, true), "test")
                    end
                end
            end

            after do
                @plan.execution_engine.display_exceptions = true
                if @shell_client && !@shell_client.closed?
                    with_polling_server do
                        @shell_client.close
                    end
                end
                @server.close unless @server.closed?
            end

            describe "#summarize_pending_messages" do
                before do
                    @shell_client = shell_client
                end

                describe "notification messages" do
                    before do
                        @app.notify("test", "INFO", "test message")
                        @shell_client.client.poll
                    end

                    it "displays them and returns their IDs" do
                        msg_ids, messages = @shell_client.summarize_pending_messages
                        assert_equal 1, messages.size
                        assert_match(/#1 \[INFO\] test: test message/, messages[0])
                        assert_equal [1], msg_ids.to_a
                    end
                    it "removes notification messages from the queue" do
                        @shell_client.summarize_pending_messages
                        assert @shell_client.client.notification_queue.empty?
                    end
                    it "hides messages that are given to it as \"already summarized\"" do
                        _, messages = @shell_client.summarize_pending_messages([1])
                        assert messages.empty?
                    end
                end
            end

            describe "#wtf?" do
                before do
                    @shell_client = shell_client
                end
                it "displays notification messages" do
                    @app.notify("test", "INFO", "test message")
                    m = flexmock(@shell_client).should_receive(:puts)
                    m.explicitly
                        .with(/-- #\d+ \(notification\) --.*\[INFO\] test: test message/m)
                        .once
                    @shell_client.client.poll
                    @shell_client.wtf?
                end
            end
        end
    end
end
