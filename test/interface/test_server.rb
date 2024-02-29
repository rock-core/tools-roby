# frozen_string_literal: true

require "roby/test/self"
require "roby/interface"

module Roby
    module Interface
        describe Server do
            describe "handshake" do
                before do
                    @notify_app = Roby::Application.new
                    @interface = Interface.new(@notify_app)
                    @notify_app.execution_engine.display_exceptions = false

                    client_io, server_io = Socket.pair(:UNIX, :STREAM, 0)
                    client_io.close
                    server_channel = Channel.new(server_io, false)
                    server_channel.reset_thread_guard(Thread.current, Thread.current)
                    @server = Server.new(server_channel, @interface)
                    flexmock(@server)
                end
                after do
                    @server.close
                end

                it "returns false in performed_handshake? before the handshake" do
                    refute @server.performed_handshake?
                end
                it "does not listen to notifications before the handshake" do
                    flexmock(@server).should_receive(:write_packet).never
                    @notify_app.ui_event(:test)
                end
                it "returns true in performed_handshake? after the handshake" do
                    @server.handshake("42", [])
                    assert @server.performed_handshake?
                end
                it "listens to notifications after the handshake" do
                    @server.handshake("42", [])
                    flexmock(@server).should_receive(:write_packet).once
                    @notify_app.ui_event(:test)
                end
                it "returns a hash of the requested commands" do
                    flexmock(@interface, commands: 42, jobs: 84)
                    result = @server.handshake("42", %i[commands jobs])
                    assert_equal Hash[commands: 42, jobs: 84], result
                end
                it "does not listen to notifications once closed" do
                    @server.handshake("42", [])
                    @server.close
                    flexmock(@server).should_receive(:write_packet).never
                    @notify_app.ui_event(:test)
                end
            end

            describe "notification and UI event handling" do
                before do
                    @notify_app = Roby::Application.new
                    @interface = Interface.new(@notify_app)
                    @notify_app.execution_engine.display_exceptions = false

                    main_thread = Thread.current
                    client_io, server_io = Socket.pair(:UNIX, :STREAM, 0)
                    server_channel = Channel.new(server_io, false)
                    server_channel.reset_thread_guard(Thread.current, Thread.current)
                    client_channel = Channel.new(client_io, true)
                    @server = Server.new(server_channel, @interface)
                    flexmock(@server)
                    @server.listen_to_notifications

                    @written_packets = []
                    flexmock(server_channel).should_receive(:write_packet)
                        .and_return do |pkt|
                            if Thread.current != main_thread
                                raise "write_packet called in invalid thread"
                            end

                            @written_packets << pkt
                        end
                    client_channel.close
                end

                after do
                    @server.close
                end

                it "has notifications enabled by default" do
                    assert @server.notifications_enabled?
                end
                it "sends notifications right away if notified from the main thread" do
                    @notify_app.notify("test", :warn, "some_message")
                    assert_equal [[:notification, "test", :warn, "some_message"]],
                                 @written_packets
                end
                it "queues notifications that come from a different thread" do
                    Thread.new { @notify_app.notify("test", :warn, "some_message") }
                        .join
                    assert_equal [], @written_packets
                end
                it "keeps order between queued notifications when a new one "\
                    "is received from the main thread" do
                    Thread.new { @notify_app.notify("thread", :warn, "some_message") }
                        .join
                    @notify_app.notify("main", :warn, "some_message")
                    expected = [
                        [:notification, "thread", :warn, "some_message"],
                        [:notification, "main", :warn, "some_message"]
                    ]
                    assert_equal expected, @written_packets
                end
                it "flushes queued notifications on write" do
                    Thread.new { @notify_app.notify("thread", :warn, "some_message") }
                        .join
                    @server.write_packet([:some, "packet"])
                    expected = [
                        [:notification, "thread", :warn, "some_message"],
                        [:some, "packet"]
                    ]
                    assert_equal expected, @written_packets
                end
                it "does not send notifications if they are disabled" do
                    @server.disable_notifications
                    refute @server.notifications_enabled?
                    @notify_app.notify("main", :warn, "some_message")
                    assert_equal [], @written_packets
                end
                it "sends new notifications once they are re-enabled" do
                    @server.disable_notifications
                    @server.enable_notifications
                    assert @server.notifications_enabled?
                    @notify_app.notify("main", :warn, "some_message")
                    assert_equal [[:notification, "main", :warn, "some_message"]],
                                 @written_packets
                end
                it "forwards UI events" do
                    @notify_app.ui_event(:test, 42)
                    assert_equal [[:ui_event, :test, 42]], @written_packets
                end
                it "queues UI events that come from a different thread" do
                    Thread.new { @notify_app.ui_event(:test, 42) }.join
                    assert_equal [], @written_packets
                    @server.write_packet([:cycle_end, {}])
                    refute @server.has_deferred_exception?
                    assert_equal [[:ui_event, :test, 42], [:cycle_end, {}]],
                                 @written_packets
                end
            end

            describe "remote calls" do
                attr_reader :interface, :server, :client_channel

                before do
                    @interface = Interface.new(Roby::Application.new)
                    interface.app.execution_engine.display_exceptions = false

                    client_io, server_io = Socket.pair(:UNIX, :STREAM, 0)
                    server_channel = Channel.new(server_io, false)
                    @client_channel = Channel.new(client_io, true)
                    @server = Server.new(server_channel, interface)
                    @server.listen_to_notifications
                    flexmock(@server)
                end

                after do
                    client_channel.close
                    server.close
                end

                it "passes call and arguments, and replies with the result of the call" do
                    flexmock(server).should_receive(:test_call)
                        .explicitly.once.with(24).and_return([42])
                    client_channel.write_packet([[], :test_call, 24])
                    server.poll
                    assert_equal [:reply, [42]], client_channel.read_packet
                end

                it "resolves the subcommand from the path argument before calling" do
                    flexmock(interface).should_receive(:sub).explicitly
                        .and_return(cmd = flexmock)
                    cmd.should_receive(:cmd).and_return(target = flexmock)
                    target.should_receive(:test_call)
                        .explicitly.once.with(24).and_return([42])
                    client_channel.write_packet([%i[sub cmd], :test_call, 24])
                    server.poll
                    assert_equal [:reply, [42]], client_channel.read_packet
                end

                it "properly handles if the argument is a Hash" do
                    flexmock(server).should_receive(:test_call)
                        .explicitly.once.with({}).and_return(42)
                    client_channel.write_packet([[], :test_call, {}])
                    server.poll
                    assert_equal [:reply, 42], client_channel.read_packet
                end

                it "properly handles if the reply is a Hash" do
                    flexmock(server).should_receive(:test_call)
                        .explicitly.once.with(24).and_return({})
                    client_channel.write_packet([[], :test_call, 24])
                    server.poll
                    assert_equal [:reply, {}], client_channel.read_packet
                end

                it "handles action models as return values" do
                    action_model = Actions::Models::Action.new("test")
                    action_model.name = "some_action"
                    flexmock(server)
                        .should_receive(:test_call)
                        .explicitly.once.and_return(action_model)
                    client_channel.write_packet([[], :test_call])
                    server.poll
                    call, model = client_channel.read_packet
                    assert_equal :reply, call
                    assert_kind_of Protocol::ActionModel, model
                    assert_equal "some_action", model.name
                end

                it "replies with :bad_call and the exception if the call raises" do
                    flexmock(server).should_receive(:test_call)
                        .explicitly.and_raise(ArgumentError.exception("test message"))
                    client_channel.write_packet([[], :test_call, 24])
                    server.poll
                    type, exception = client_channel.read_packet
                    assert_equal :bad_call, type
                    assert_kind_of Protocol::Error, exception
                    assert_equal "test message (ArgumentError)", exception.message.chomp
                end

                it "processes all calls from a batch and returns "\
                    "all their return values" do
                    flexmock(server).should_receive(:test_call)
                        .explicitly.once.with(24).and_return([42])
                    flexmock(server).should_receive(:test_call)
                        .explicitly.once.with(12).and_return([24])
                    client_channel.write_packet(
                        [
                            [], :process_batch, [
                                [[], :test_call, 24], [[], :test_call, 12]
                            ]
                        ])
                    server.poll
                    assert_equal [:reply, [[42], [24]]], client_channel.read_packet
                end

                it "resolves subcommands as specified in the batch" do
                    flexmock(interface).should_receive(:sub).explicitly
                        .and_return(cmd = flexmock)
                    cmd.should_receive(:cmd).and_return(target = flexmock)
                    target.should_receive(:test_call)
                        .explicitly.once.with(12).and_return(84)
                    target.should_receive(:test_call)
                        .explicitly.once.with(24).and_return(42)
                    client_channel.write_packet(
                        [
                            [], :process_batch, [
                                [%i[sub cmd], :test_call, 24],
                                [%i[sub cmd], :test_call, 12]
                            ]
                        ])
                    server.poll
                    assert_equal [:reply, [42, 84]], client_channel.read_packet
                end

                it "replies with :bad_call and the exception "\
                    "if any of the calls raises" do
                    flexmock(server).should_receive(:test_call)
                        .explicitly.once.with(24).and_return([42])
                    flexmock(server).should_receive(:test_call)
                        .explicitly.and_raise(ArgumentError.exception("test message"))
                    client_channel.write_packet(
                        [
                            [], :process_batch, [
                                [[], :test_call, 24], [[], :test_call, 12]
                            ]
                        ])
                    server.poll
                    type, exception = client_channel.read_packet
                    assert_equal :bad_call, type
                    assert_kind_of Protocol::Error, exception
                    assert_equal "test message (ArgumentError)", exception.message.chomp
                end
            end

            describe "error handling" do
                attr_reader :interface, :server, :server_io, :error_m

                before do
                    @interface = Interface.new(Roby::Application.new)
                    interface.app.execution_engine.display_exceptions = false
                    @server_io = flexmock
                    @server_io.should_receive(:allow_classes)
                    @server_io.should_receive(:add_marshaller)
                    @server = Server.new(@server_io, interface)
                    flexmock(@server)
                    @server.listen_to_notifications
                    @com_error_m = Class.new(ComError)
                    @error_m = Class.new(RuntimeError)
                end

                def self.handler_error_behaviour(&block)
                    it "defers non-ComError exceptions" do
                        server_io.should_receive(:write_packet).and_raise(error_m)
                        instance_eval(&block)
                        assert_raises(error_m) { server.poll }
                    end

                    it "defers ComError exceptions" do
                        server_io.should_receive(:write_packet).and_raise(ComError)
                        instance_eval(&block)
                        assert_raises(ComError) { server.poll }
                    end
                end

                describe "the on_cycle_end handler" do
                    handler_error_behaviour { interface.notify_cycle_end }
                end

                describe "the notification handler" do
                    handler_error_behaviour do
                        interface.app.notify "bla", "blu", "blo"
                    end
                end

                describe "the job handler" do
                    handler_error_behaviour do
                        interface.job_notify JOB_MONITORED, 10, "test"
                        interface.push_pending_notifications
                    end
                end

                it "passes a non-ComError if read_packet raises" do
                    server_io.should_receive(:read_packet)
                        .and_raise(error_m.exception("test message"))
                    msg = assert_raises(error_m) { server.poll }
                    assert_match(/test message/, msg.message)
                end

                it "passes a ComError from #read_packet as-is" do
                    server_io.should_receive(:read_packet)
                        .and_raise(ComError.exception("test message"))
                    msg = assert_raises(ComError) { server.poll }
                    assert_equal "test message", msg.message
                end

                def self.request_handling_behaviour
                    it "passes an exception raised by writing a bad_call" do
                        e = Exception.exception "test message"
                        server.should_receive(:process_call)
                            .with([], :test).and_raise(e)
                        server_io.should_receive(:write_packet)
                            .with([:bad_call, e])
                            .and_raise(error_m.exception("test message"))

                        msg = assert_raises(error_m) { server.poll }
                        assert_match "test message", msg.message
                    end

                    it "passes a ComError raised by writing a bad_call" do
                        e = @error_m.exception "test"
                        server.should_receive(:process_call)
                            .with([], :test).and_raise(e)
                        server_io.should_receive(:write_packet)
                            .with([:bad_call, e])
                            .and_raise(@com_error_m.exception("test message"))

                        msg = assert_raises(@com_error_m) { server.poll }
                        assert_equal "test message", msg.message
                    end

                    it "passes a ComError raised by writing a reply" do
                        server_io.should_receive(:write_packet)
                            .with([:reply, @ret])
                            .and_raise(@com_error_m.exception("test message"))

                        msg = assert_raises(@com_error_m) { server.poll }
                        assert_match "test message", msg.message
                    end

                    it "notifies the remote side of a non-ComError exception that "\
                        "was raised during reply marshalling, and fails the local side" do
                        reply_e = @error_m.exception("test message")
                        server_io.should_receive(:write_packet)
                            .with([:reply, @ret])
                            .and_raise(reply_e)
                        server_io.should_receive(:write_packet)
                            .with([:protocol_error, reply_e])
                            .once

                        msg = assert_raises(@error_m) { server.poll }
                        assert_equal "test message", msg.message
                    end

                    it "raises in poll if both reply and bad_call failed" do
                        reply_e = @error_m.exception("reply message")
                        server_io.should_receive(:write_packet)
                            .with([:reply, @ret])
                            .and_raise(reply_e)
                        server_io.should_receive(:write_packet)
                            .with([:protocol_error, reply_e])
                            .and_raise(@error_m.exception("test message"))

                        msg = assert_raises(@error_m) { server.poll }
                        assert_equal "test message", msg.message
                    end
                end

                describe "while handling a request" do
                    before do
                        server_io.should_receive(:read_packet)
                            .and_return([[], :test])
                        server.should_receive(:process_call)
                            .with([], :test)
                            .and_return(@ret = flexmock).by_default
                    end
                    request_handling_behaviour
                end

                describe "while handling a batch" do
                    before do
                        server_io.should_receive(:read_packet)
                            .and_return([[], :process_batch, [[[], :test]]])
                        server.should_receive(:process_call)
                            .with([], :test)
                            .and_return(ret = flexmock).by_default
                        @ret = [ret]
                    end
                    request_handling_behaviour
                end
            end
        end
    end
end
