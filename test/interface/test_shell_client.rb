require 'roby/test/self'
require 'socket'
require 'roby/interface/shell_client'
require 'roby/interface/tcp'

module Roby
    module Interface
        describe ShellClient do
            before do
                @app = Roby::Application.new
                @plan = @app.plan
                register_plan(@plan)

                @interface = flexmock(Interface.new(@app))

                server_socket, @client_socket = Socket.pair(:UNIX, :DGRAM, 0) 
                @server    = Server.new(DRobyChannel.new(server_socket, false), @interface)
                @server_thread = Thread.new do
                    plan.execution_engine.thread = Thread.current
                    begin
                        while true
                            @server.poll
                            sleep 0.01
                        end
                    rescue ComError
                    end
                end
                @server_thread.abort_on_exception = true
            end

            let :shell_client do
                ShellClient.new 'remote' do
                    Client.new(DRobyChannel.new(@client_socket, true), 'test')
                end
            end

            after do
                @plan.execution_engine.display_exceptions = true
                if @shell_client
                    @shell_client.close if !@shell_client.closed?
                end
                @server.close if !@server.closed?
                begin @server_thread.join
                rescue Interrupt
                end
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
                        validator = flexmock
                        validator.should_receive(:call).once.
                            with(/#1 \[INFO\] test: test message/)
                        msg_ids = @shell_client.summarize_pending_messages do |msg|
                            validator.call(msg)
                        end
                        assert_equal [1], msg_ids.to_a
                    end
                    it "removes notification messages from the queue" do
                        @shell_client.summarize_pending_messages do |msg|
                        end
                        assert @shell_client.client.notification_queue.empty?
                    end
                    it "hides messages that are given to it as \"already summarized\"" do
                        validator = flexmock
                        validator.should_receive(:call).never
                        @shell_client.summarize_pending_messages([1]) do |msg|
                            validator.call
                        end
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
                    m.explicitly.
                        with(/-- #\d+ \(notification\) --.*\[INFO\] test: test message/m).
                        once
                    @shell_client.client.poll
                    @shell_client.wtf?
                end
            end
        end
    end
end

