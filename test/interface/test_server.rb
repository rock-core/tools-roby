require 'roby/test/self'

module Roby
    module Interface
        describe Server do

            describe "remote calls" do
                attr_reader :interface, :server, :client_channel
                before do
                    @interface = Interface.new(Roby::Application.new)
                    interface.app.execution_engine.display_exceptions = false

                    client_io, server_io = Socket.pair(:UNIX, :STREAM, 0)
                    server_channel = DRobyChannel.new(server_io, false)
                    @client_channel = DRobyChannel.new(client_io, true)
                    @server = Server.new(server_channel, interface)
                    flexmock(@server)
                end

                after do
                    client_channel.close
                    server.close
                end
            
                it "passes call and arguments, and replies with the result of the call" do
                    flexmock(server).should_receive(:test_call).
                        explicitly.once.with(24).and_return([42])
                    client_channel.write_packet([[], :test_call, 24])
                    server.poll
                    assert_equal [:reply, [42]], client_channel.read_packet
                end
            
                it "properly handles if the argument is a Hash" do
                    flexmock(server).should_receive(:test_call).
                        explicitly.once.with(Hash.new).and_return(42)
                    client_channel.write_packet([[], :test_call, Hash.new])
                    server.poll
                    assert_equal [:reply, 42], client_channel.read_packet
                end

                it "properly handles if the reply is a Hash" do
                    flexmock(server).should_receive(:test_call).
                        explicitly.once.with(24).and_return(Hash.new)
                    client_channel.write_packet([[], :test_call, 24])
                    server.poll
                    assert_equal [:reply, Hash.new], client_channel.read_packet
                end

                it "replies with :bad_call and the exception if the call raises" do
                    flexmock(server).should_receive(:test_call).
                        explicitly.and_raise(ArgumentError.exception("test message"))
                    client_channel.write_packet([[], :test_call, 24])
                    server.poll
                    type, exception = client_channel.read_packet
                    assert_equal :bad_call, type
                    assert_kind_of ArgumentError, exception
                    assert_equal "test message", exception.message
                end
            
                it "processes all calls from a batch and returns all their return values" do
                    flexmock(server).should_receive(:test_call).
                        explicitly.once.with(24).and_return([42])
                    flexmock(server).should_receive(:test_call).
                        explicitly.once.with(12).and_return([24])
                    client_channel.write_packet([[], :process_batch, [[[], :test_call, 24], [[], :test_call, 12]]])
                    server.poll
                    assert_equal [:reply, [[42], [24]]], client_channel.read_packet
                end

                it "replies with :bad_call and the exception if any of the calls raises" do
                    flexmock(server).should_receive(:test_call).
                        explicitly.once.with(24).and_return([42])
                    flexmock(server).should_receive(:test_call).
                        explicitly.and_raise(ArgumentError.exception('test message'))
                    client_channel.write_packet([[], :process_batch, [[[], :test_call, 24], [[], :test_call, 12]]])
                    server.poll
                    type, exception = client_channel.read_packet
                    assert_equal :bad_call, type
                    assert_kind_of ArgumentError, exception
                    assert_equal "test message", exception.message
                end
            end

            describe "error handling" do
                attr_reader :interface, :server, :server_io, :error_m
                before do
                    @interface = Interface.new(Roby::Application.new)
                    interface.app.execution_engine.display_exceptions = false
                    @server_io = flexmock
                    @server = Server.new(@server_io, interface)
                    flexmock(@server)
                    @error_m = Class.new(Exception)
                end

                describe "abort_on_exception: true" do
                    before do
                        server.abort_on_exception = true
                    end

                    def self.handler_error_behaviour(&block)
                        it "propagates non-ComError exceptions" do
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
                        handler_error_behaviour { interface.app.notify "bla", "blu", "blo" }
                    end

                    describe "the job handler" do
                        handler_error_behaviour do
                            interface.job_notify JOB_MONITORED, 10, 'test'
                            interface.push_pending_job_notifications
                        end
                    end

                    describe "the exception handler" do
                        handler_error_behaviour do
                            interface.app.execution_engine.notify_exception \
                                "test", error_m, []
                        end
                    end

                    it "passes a non-ComError if read_packet raises" do
                        server_io.should_receive(:read_packet).
                            and_raise(error_m.exception("test message"))
                        msg = assert_raises(error_m) { server.poll }
                        assert_match /test message/, msg.message
                    end

                    it "passes a ComError from #read_packet as-is" do
                        server_io.should_receive(:read_packet).
                            and_raise(ComError.exception("test message"))
                        msg = assert_raises(ComError) { server.poll }
                        assert_equal "test message", msg.message
                    end

                    def self.request_handling_behaviour
                        it "raises ComError if a bad_call feedback fails" do
                            e = Exception.exception 'test message'
                            server.should_receive(:process_call).
                                with([], :test).and_raise(e)
                            server_io.should_receive(:write_packet).
                                with([:bad_call, e]).
                                and_raise(error_m.exception("test message"))

                            msg = assert_raises(error_m) { server.poll }
                            assert_match "test message", msg.message
                        end

                        it "passes a ComError raised by writing a bad_call as-is" do
                            e = Exception.exception 'test message'
                            server.should_receive(:process_call).
                                with([], :test).and_raise(e)
                            server_io.should_receive(:write_packet).
                                with([:bad_call, e]).
                                and_raise(ComError.exception("test message"))

                            msg = assert_raises(ComError) { server.poll }
                            assert_equal "test message", msg.message
                        end

                        it "raises ComError if writing the reply fails" do
                            server_io.should_receive(:write_packet).
                                with([:reply, @ret]).
                                and_raise(error_m.exception("test message"))

                            msg = assert_raises(error_m) { server.poll }
                            assert_match "test message", msg.message
                        end

                        it "passes a ComError raised by sending a reply as-is" do
                            server_io.should_receive(:write_packet).
                                with([:reply, @ret]).
                                and_raise(ComError.exception("test message"))

                            msg = assert_raises(ComError) { server.poll }
                            assert_equal "test message", msg.message
                        end
                    end

                    describe "while handling a request" do
                        before do
                            server_io.should_receive(:read_packet).
                                and_return([[], :test])
                            server.should_receive(:process_call).
                                with([], :test).
                                and_return(@ret = flexmock).by_default
                        end
                        request_handling_behaviour
                    end

                    describe "while handling a batch" do
                        before do
                            server_io.should_receive(:read_packet).
                                and_return([[], :process_batch, [[[], :test]]])
                            server.should_receive(:process_call).
                                with([], :test).
                                and_return(ret = flexmock).by_default
                            @ret = [ret]
                        end
                        request_handling_behaviour
                    end
                end

                describe "abort_on_exception: false" do
                    before do
                        server.abort_on_exception = false
                    end

                    def self.handler_error_behaviour(&block)
                        it "defers non-ComError exceptions and turns them into ComError in #poll" do
                            server_io.should_receive(:write_packet).and_raise(error_m)
                            instance_eval(&block)
                            assert_raises(ComError) { server.poll }
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
                        handler_error_behaviour { interface.app.notify "bla", "blu", "blo" }
                    end

                    describe "the job handler" do
                        handler_error_behaviour do
                            interface.job_notify JOB_MONITORED, 10, 'test'
                            interface.push_pending_job_notifications
                        end
                    end

                    describe "the exception handler" do
                        handler_error_behaviour do
                            interface.app.execution_engine.notify_exception \
                                "test", error_m, []
                        end
                    end

                    it "passes a non-ComError if read_packet raises" do
                        server_io.should_receive(:read_packet).
                            and_raise(error_m.exception("test message"))
                        msg = assert_raises(ComError) { server.poll }
                        assert_match /test message/, msg.message
                    end

                    it "passes a ComError from #read_packet as-is" do
                        server_io.should_receive(:read_packet).
                            and_raise(ComError.exception("test message"))
                        msg = assert_raises(ComError) { server.poll }
                        assert_equal "test message", msg.message
                    end

                    def self.request_handling_behaviour
                        it "raises ComError if a bad_call feedback fails" do
                            e = Exception.exception 'test message'
                            server.should_receive(:process_call).
                                with([], :test).and_raise(e)
                            server_io.should_receive(:write_packet).
                                with([:bad_call, e]).
                                and_raise(error_m.exception("test message"))

                            msg = assert_raises(ComError) { server.poll }
                            assert_match "test message", msg.message
                        end

                        it "passes a ComError raised by writing a bad_call as-is" do
                            e = Exception.exception 'test message'
                            server.should_receive(:process_call).
                                with([], :test).and_raise(e)
                            server_io.should_receive(:write_packet).
                                with([:bad_call, e]).
                                and_raise(ComError.exception("test message"))

                            msg = assert_raises(ComError) { server.poll }
                            assert_equal "test message", msg.message
                        end

                        it "raises ComError if writing the reply fails" do
                            server_io.should_receive(:write_packet).
                                with([:reply, @ret]).
                                and_raise(error_m.exception("test message"))

                            msg = assert_raises(ComError) { server.poll }
                            assert_match "test message", msg.message
                        end

                        it "passes a ComError raised by sending a reply as-is" do
                            server_io.should_receive(:write_packet).
                                with([:reply, @ret]).
                                and_raise(ComError.exception("test message"))

                            msg = assert_raises(ComError) { server.poll }
                            assert_equal "test message", msg.message
                        end
                    end

                    describe "while handling a request" do
                        before do
                            server_io.should_receive(:read_packet).
                                and_return([[], :test])
                            server.should_receive(:process_call).
                                with([], :test).
                                and_return(@ret = flexmock).by_default
                        end
                        request_handling_behaviour
                    end

                    describe "while handling a batch" do
                        before do
                            server_io.should_receive(:read_packet).
                                and_return([[], :process_batch, [[[], :test]]])
                            server.should_receive(:process_call).
                                with([], :test).
                                and_return(ret = flexmock).by_default
                            @ret = [ret]
                        end
                        request_handling_behaviour
                    end
                end
            end
        end
    end
end

