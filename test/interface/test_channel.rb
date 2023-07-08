# frozen_string_literal: true

require "roby/test/self"
require "roby/interface"

module Roby
    module Interface
        describe Channel do
            before do
                @io_r, @io_w = Socket.pair(:UNIX, :STREAM, 0)
            end
            after do
                @io_r.close unless @io_r.closed?
                @io_w.close unless @io_w.closed?
            end
            it "does not block on read" do
                channel = Channel.new(@io_r, false)
                assert_nil channel.read_packet
            end
            it "waits 'timeout' seconds" do
                channel = Channel.new(@io_r, false)
                before = Time.now
                assert_nil channel.read_packet(0.1)
                assert(Time.now - before > 0.1)
            end
            it "waits forever if the timeout is nil" do
                channel = Channel.new(@io_r, false)
                read_thread = Thread.new { channel.read_packet(nil) }
                loop { break if read_thread.stop? }

                writer = Channel.new(@io_w, true)
                writer.write_packet({})
                assert_equal({}, read_thread.value)
            end
            it "does not block on write" do
                io_w_buffer_size =
                    @io_w.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF).int
                @io_w.write("0" * io_w_buffer_size)
                # Just make sure ...
                channel = Channel.new(@io_w, false)
                assert_raises(Errno::EAGAIN) { @io_w.syswrite(" ") }

                channel.write_packet({})
            end
            it "handles partial packets on write" do
                channel = Channel.new(@io_w, false)
                io_w_buffer_size =
                    @io_w.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF).int
                @io_w.write("0" * (io_w_buffer_size / 2))
                channel.push_write_data("1" * io_w_buffer_size)
                assert channel.write_buffer_size < io_w_buffer_size

                assert_equal "0" * (io_w_buffer_size / 2),
                             @io_r.read(io_w_buffer_size / 2)
                channel.push_write_data
                assert_equal("1" * io_w_buffer_size, @io_r.read(io_w_buffer_size))
            end
            it "raises ComError if the internal write buffer reaches its maximum size" do
                channel = Channel.new(@io_w, false, max_write_buffer_size: 1024)
                io_w_buffer_size =
                    @io_w.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF).int
                @io_w.write("1" * io_w_buffer_size)
                channel.push_write_data("1" * 1024)

                assert_raises(ComError) do
                    channel.push_write_data "2"
                end
            end

            describe "connections closed" do
                it "raises ComError on writing a closed IO" do
                    channel = Channel.new(@io_w, true)
                    @io_w.close
                    assert_raises(ComError) { channel.write_packet({}) }
                end
                it "raises ComError on reading a closed IO" do
                    channel = Channel.new(@io_r, true)
                    @io_r.close
                    assert_raises(ComError) { channel.read_packet }
                end
                it "raises ComError on writing a pipe whose other end is closed" do
                    channel = Channel.new(@io_w, true)
                    @io_r.close
                    assert_raises(ComError) { channel.write_packet({}) }
                end
                it "raises ComError on reading a pipe whose other end is closed" do
                    channel = Channel.new(@io_r, true)
                    @io_w.close
                    assert_raises(ComError) { channel.read_packet }
                end
                it "raises ComError on writing a socket whose other end is closed" do
                    channel = Channel.new(@io_w, true)
                    @io_r.close
                    assert_raises(ComError) { channel.write_packet({}) }
                end
                it "raises ComError on reading a socket whose other end is closed" do
                    channel = Channel.new(@io_r, true)
                    @io_w.close
                    assert_raises(ComError) { channel.read_packet }
                end
                it "raises ComError if writing the socket raises SystemCallError "\
                   "a.k.a. any of the Errno constants" do
                    flexmock(@io_w).should_receive(:syswrite)
                                   .and_raise(SystemCallError.new("test", 0))
                    channel = Channel.new(@io_w, true)
                    @io_r.close
                    assert_raises(ComError) { channel.write_packet([]) }
                end
                it "raises ComError if reading the socket raises SystemCallError "\
                   "a.k.a. any of the Errno constants" do
                    flexmock(@io_r).should_receive(:sysread)
                                   .and_raise(SystemCallError.new("test", 0))
                    channel = Channel.new(@io_r, true)
                    @io_w.close
                    assert_raises(ComError) { channel.read_packet }
                end
            end

            describe "packet transmission" do
                before do
                    @server = Channel.new(@io_w, false)
                    @client = Channel.new(@io_r, true)
                end

                it "marshals an action model on send" do
                    action_model = Actions::Models::Action.new("test")
                    action_model.name = "action_model"
                    @server.write_packet(action_model)
                    ret = @client.read_packet
                    assert_kind_of Protocol::ActionModel, ret
                    assert_equal "action_model", ret.name
                end

                it "marshals an action argument on send" do
                    action_model = Actions::Models::Action.new("test")
                    action_model.name = "action_model"
                    action_model.arguments <<
                        Actions::Models::Action::Argument.new("arg")
                    @server.write_packet(action_model)
                    ret = @client.read_packet
                    assert_kind_of Protocol::ActionModel, ret
                    assert_equal "action_model", ret.name

                    arg_out = ret.arguments.first
                    assert_kind_of Protocol::ActionArgument, arg_out
                    assert_equal "arg", arg_out.name
                end

                it "handles the Void null type from actions" do
                    action_model = Actions::Models::Action.new("test")
                    action_model.name = "action_model"
                    action_model.arguments <<
                        Actions::Models::Action::Argument.new(
                            "arg", "bla", false, nil, Actions::Models::Action::Void
                        )
                    @server.write_packet(action_model)
                    ret = @client.read_packet
                    assert_kind_of Protocol::ActionModel, ret
                    assert_equal "action_model", ret.name

                    arg_out = ret.arguments.first
                    assert_kind_of Protocol::ActionArgument, arg_out
                    assert_equal "arg", arg_out.name
                    assert_kind_of Protocol::VoidClass, arg_out.example
                end

                it "marshals an execution exception object" do
                    plan.add(parent = Task.new)
                    plan.add(child = Task.new)
                    localized_error = Roby::LocalizedError.new(child)
                    e = Roby::ExecutionException.new(localized_error)
                    e.propagate(child, parent)

                    @server.write_packet(e)
                    ret = @client.read_packet
                    assert_kind_of Protocol::ExecutionException, ret
                    assert_equal "Roby::LocalizedError", ret.exception.class_name
                    assert_equal child.droby_id.id, ret.failed_task.id
                    assert_equal Set[parent.droby_id.id, child.droby_id.id],
                                 ret.involved_tasks.map(&:id).to_set

                end
            end

            describe "marshalling" do
            end
        end
    end
end
