# frozen_string_literal: true

require "roby/test/self"
require "roby/interface/v2"

module Roby
    module Interface
        module V2
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
                it "raises ComError if the internal write buffer "\
                   "reaches its maximum size" do
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

                describe "marshal_filter_object" do
                    before do
                        @channel = flexmock(Channel.new(@io_w, false))
                    end

                    it "marshals an array" do
                        array = 10.times.map { Object.new }
                        @channel.should_receive(:marshal_filter_object)
                                .with(array).pass_thru
                        array.each_with_index do |o, i|
                            @channel.should_receive(:marshal_filter_object)
                                    .with(o).and_return { i }
                        end
                        assert_equal (0...10).to_a, @channel.marshal_filter_object(array)
                    end

                    it "marshals a set" do
                        set = 10.times.map { Object.new }.to_set
                        set.each_with_index do |o, i|
                            @channel.should_receive(:marshal_filter_object)
                                    .with(o).and_return { i }
                        end
                        @channel.should_receive(:marshal_filter_object)
                                .with(set).pass_thru
                        assert_equal (0...10).to_set, @channel.marshal_filter_object(set)
                    end

                    it "marshals only hash values" do
                        values = 10.times.map { Object.new }
                        values.each_with_index do |o, i|
                            @channel.should_receive(:marshal_filter_object)
                                    .with(o).and_return { i }
                        end
                        keys = 10.times.map { _1 * 10 }
                        keys.each do |k|
                            @channel.should_receive(:marshal_filter_object).with(k).never
                        end

                        hash = Hash[keys.zip(values)]
                        @channel.should_receive(:marshal_filter_object)
                                .with(hash).pass_thru

                        expected = Hash[keys.zip(0...10)]
                        assert_equal(
                            expected, @channel.marshal_filter_object(hash)
                        )
                    end

                    it "marshals structs values" do
                        s_class = Struct.new :a, :b, :c
                        values = 3.times.map { Object.new }
                        s = s_class.new(*values)
                        values.each_with_index do |o, i|
                            @channel.should_receive(:marshal_filter_object)
                                    .with(o).ordered.and_return { i }
                        end
                        expected = s_class.new(0, 1, 2)
                        @channel.should_receive(:marshal_filter_object).with(s).pass_thru
                        assert_equal(
                            expected, @channel.marshal_filter_object(s)
                        )
                    end

                    it "returns booleans as-is" do
                        assert_equal false, @channel.marshal_filter_object(false)
                        assert_equal true, @channel.marshal_filter_object(true)
                    end

                    it "returns nil as-is" do
                        assert_nil @channel.marshal_filter_object(nil)
                    end

                    it "returns numbers as-is" do
                        assert_equal 10, @channel.marshal_filter_object(10)
                        assert_equal 10.1, @channel.marshal_filter_object(10.1)
                    end

                    it "returns strings as-is" do
                        assert_equal "10", @channel.marshal_filter_object("10")
                    end

                    it "returns symbols as-is" do
                        assert_equal(:a, @channel.marshal_filter_object(:a))
                    end

                    it "returns times as-is" do
                        t = Time.now
                        assert_equal t, @channel.marshal_filter_object(t)
                    end

                    it "returns ranges as-is" do
                        assert_equal (0..20), @channel.marshal_filter_object((0..20))
                    end

                    it "returns any objects whose class was set up with "\
                       "#allow_classes as is" do
                        k = Class.new
                        o = k.new
                        @channel.allow_classes(k)
                        assert_equal o, @channel.marshal_filter_object(o)
                    end

                    it "returns any objects which has been allowed explicitly" do
                        objects = [Class.new.new, Object.new]
                        @channel.allow_objects(*objects)
                        assert_equal objects,
                                     @channel.marshal_filter_object(objects)
                    end

                    it "allows setting up marshallers for specific classes" do
                        k = Class.new
                        o = k.new
                        ret_class = Struct.new(:channel, :value)
                        @channel.add_marshaller(k) { ret_class.new(_1, _2) }

                        ret = @channel.marshal_filter_object(o)
                        assert_equal @channel, ret.channel
                        assert_equal o, ret.value
                    end

                    it "will pick up a marshaller for a base class "\
                       "if there is none for the exact class" do
                        base = Class.new
                        o = Class.new(base).new
                        ret_class = Struct.new(:channel, :value)
                        @channel.add_marshaller(base) { ret_class.new(_1, _2) }

                        ret = @channel.marshal_filter_object(o)
                        assert_equal @channel, ret.channel
                        assert_equal o, ret.value
                    end

                    it "will use the marshaller for the exact class "\
                       "even if there is one for the base class" do
                        base = Class.new
                        k = Class.new(base)
                        o = k.new
                        ret_class = Struct.new(:channel, :value)
                        @channel.add_marshaller(base) { 42 }
                        @channel.add_marshaller(k) { ret_class.new(_1, _2) }

                        ret = @channel.marshal_filter_object(o)
                        assert_equal @channel, ret.channel
                        assert_equal o, ret.value
                    end

                    it "will use the marshaller for the most specialized class in the "\
                       "inheritance chain" do
                        base = Class.new
                        middle = Class.new(base)
                        k = Class.new(middle)
                        o = k.new
                        ret_class = Struct.new(:channel, :value)
                        @channel.add_marshaller(base) { 42 }
                        @channel.add_marshaller(middle) { ret_class.new(_1, _2) }

                        ret = @channel.marshal_filter_object(o)
                        assert_equal @channel, ret.channel
                        assert_equal o, ret.value
                    end

                    it "handles new marshallers being added at runtime" do
                        base = Class.new
                        middle = Class.new(base)
                        k = Class.new(middle)
                        o = k.new
                        ret_class = Struct.new(:channel, :value)
                        @channel.add_marshaller(base) { 42 }
                        assert_equal 42, @channel.marshal_filter_object(o)

                        @channel.add_marshaller(middle) { ret_class.new(_1, _2) }
                        ret = @channel.marshal_filter_object(o)
                        assert_equal @channel, ret.channel
                        assert_equal o, ret.value
                    end
                end
            end
        end
    end
end
