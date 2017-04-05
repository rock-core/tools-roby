require 'roby/test/self'

module Roby
    module Interface
        describe DRobyChannel do
            before do
                @io_r, @io_w = Socket.pair(:UNIX, :STREAM, 0)
            end
            after do
                @io_r.close if !@io_r.closed?
                @io_w.close if !@io_w.closed?
            end
            it "does not block on read" do
                channel = DRobyChannel.new(@io_r, false)
                assert_nil channel.read_packet
            end
            it "waits 'timeout' seconds" do
                channel = DRobyChannel.new(@io_r, false)
                before = Time.now
                assert_nil channel.read_packet(0.1)
                assert(Time.now - before > 0.1)
            end
            it "waits forever if the timeout is nil" do
                channel = DRobyChannel.new(@io_r, false)
                read_thread = Thread.new { channel.read_packet(nil) }
                loop { break if read_thread.stop? }

                writer = DRobyChannel.new(@io_w, true)
                writer.write_packet(Hash.new)
                assert_equal Hash.new, read_thread.value
            end
            it "does not block on write" do
                io_w_buffer_size = @io_w.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF).int
                @io_w.write("0" * io_w_buffer_size) 
                # Just make sure ...
                assert_raises(IO::WaitWritable) { @io_w.write_nonblock(" ") }

                channel = DRobyChannel.new(@io_w, false)
                channel.write_packet(Hash.new)
            end
            it "handles partial packets on write" do
                channel = DRobyChannel.new(@io_w, false)
                io_w_buffer_size = @io_w.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF).int
                @io_w.write("0" * (io_w_buffer_size/2))
                channel.push_write_data("1" * io_w_buffer_size)
                assert channel.write_buffer_size < io_w_buffer_size

                assert_equal "0" * (io_w_buffer_size/2), @io_r.read(io_w_buffer_size/2)
                channel.push_write_data
                assert_equal("1" * io_w_buffer_size, @io_r.read(io_w_buffer_size))
            end
            it "raises ComError if the internal write buffer reaches its maximum size" do
                channel = DRobyChannel.new(@io_w, false, max_write_buffer_size: 1024)
                io_w_buffer_size = @io_w.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF).int
                @io_w.write("1" * io_w_buffer_size)
                channel.push_write_data("1" * 1024)

                assert_raises(ComError) do
                    channel.push_write_data "2"
                end
            end

            describe "connections closed" do
                it "raises ComError on writing a closed IO" do
                    channel = DRobyChannel.new(@io_w, true)
                    @io_w.close
                    assert_raises(ComError) { channel.write_packet(Hash.new) }
                end
                it "raises ComError on reading a closed IO" do
                    channel = DRobyChannel.new(@io_r, true)
                    @io_r.close
                    assert_raises(ComError) { channel.read_packet }
                end
                it "raises ComError on writing a pipe whose other end is closed" do
                    channel = DRobyChannel.new(@io_w, true)
                    @io_r.close
                    assert_raises(ComError) { channel.write_packet(Hash.new) }
                end
                it "raises ComError on reading a pipe whose other end is closed" do
                    channel = DRobyChannel.new(@io_r, true)
                    @io_w.close
                    assert_raises(ComError) { channel.read_packet }
                end
                it "raises ComError on writing a socket whose other end is closed" do
                    io_r, io_w = Socket.pair(:UNIX, :STREAM, 0)
                    channel = DRobyChannel.new(io_w, true)
                    io_r.close
                    assert_raises(ComError) { channel.write_packet(Hash.new) }
                end
                it "raises ComError on reading a socket whose other end is closed" do
                    io_r, io_w = Socket.pair(:UNIX, :STREAM, 0)
                    channel = DRobyChannel.new(io_r, true)
                    io_w.close
                    assert_raises(ComError) { channel.read_packet }
                end
            end

            describe "packet transmission" do
                def assert_can_transmit(source, destination)
                    obj_send, obj_receive = flexmock, flexmock
                    flexmock(source.marshaller).should_receive(:dump).with(obj_send).
                        and_return(10)
                    flexmock(destination.marshaller).should_receive(:local_object).with(10).
                        and_return(obj_receive)
                    source.write_packet(obj_send)
                    assert_equal obj_receive, destination.read_packet(1)
                end

                it "transmits from client to server using the provided droby-marshaller" do
                    client = DRobyChannel.new(@io_w, true)
                    server = DRobyChannel.new(@io_r, false)
                    assert_can_transmit client, server
                end
                it "transmits from server to client using the provided droby-marshaller" do
                    server = DRobyChannel.new(@io_w, false)
                    client = DRobyChannel.new(@io_r, true)
                    assert_can_transmit server, client
                end
            end
        end
    end
end

