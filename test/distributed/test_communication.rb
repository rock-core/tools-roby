require 'roby/test/distributed'
require 'roby/distributed'

class TC_DistributedCommunication < Minitest::Test
    attr_reader :local_peer
    module FakePeerServerMethods
	def reply(mock, value)
	    mock.method_called(value) if mock
	    value
	end
	def reply_error(count)
	    @error_count ||= count
	    if @error_count == 0
		return
	    end

	    @error_count -= 1
	    raise
	end

	def reply_with_callback(mock, value)
	    peer.disable_tx
	    mock.method_called(value)
	    peer.transmit(:reply, mock, value + 1)
	    mock.method_called(value + 2)
	    peer.enable_tx
	    value
	end

	def recursive_callbacks
	    peer.transmit(:recursive_callbacks)
	end

	def setup(server); peer.setup(server) end
	def peer_drb_object; DRbObject.new(peer) end
    end

    def setup
	super

	peer2peer do |remote|
	    def remote.install_fake_methods
		local_peer.local_server.extend FakePeerServerMethods
	    end
	end

	remote_peer.local_server.extend FakePeerServerMethods
	remote.install_fake_methods
    end

    def test_transmit
	FlexMock.use do |mock|
	    # Check that nothing is sent while the link is not alive
	    remote_peer.disable_tx
	    remote_peer.transmit(:reply, DRbObject.new(mock), 42) do |result|
		mock.block_called(result)
	    end

	    remote_peer.transmit(:reply, DRbObject.new(mock), 24)
	    remote_peer.transmit(:reply, DRbObject.new(mock), 24) do |result|
		mock.block_called(result)
	    end

	    mock.should_receive(:link_alive).once.ordered
	    mock.should_receive(:method_called).with(42).once.ordered(:first_call)
	    mock.should_receive(:method_called).with(24).twice.ordered(:second_calls)
	    mock.should_receive(:block_called).with(42).once.ordered(:second_calls)
	    mock.should_receive(:block_called).with(24).once.ordered

	    mock.link_alive
	    remote_peer.enable_tx
	    remote_peer.synchro_point
	end
    end

    def disable_logging
        remote.disable_logging
        logger = Roby::Distributed.logger
        old_loglevel = logger.level
        logger.level = Logger::UNKNOWN
        yield
    ensure
        remote.enable_logging
        logger.level = old_loglevel
    end

    def test_transmit_error
	FlexMock.use do |mock|
	    remote_peer.disable_tx
	    remote_peer.transmit(:reply_error, 2) do |result|
		mock.block_called
	    end
	    mock.should_receive(:block_called).never
            disable_logging do
                remote_peer.enable_tx
                assert_raises(Roby::Distributed::DisconnectedError) { remote_peer.synchro_point }
            end

	    assert(!remote_peer.connected?)
	end
    end
    
    def test_call(value = 42)
	FlexMock.use do |mock|
	    mock.should_receive(:method_called).with(value).once
	    assert_equal(value, remote_peer.call(:reply, DRbObject.new(mock), value))
	end
    end

    def test_concurrent_calls
	remote_peer.disable_tx

	t1 = Thread.new { test_call(42) }
	# wait for the TX thread to notice the new entry in the queue and
	# wake up
	sleep(0.5)

	t2 = Thread.new { test_call(21) }
	# Wait for +t2+ to insert its entry in the TX queue
	sleep(0.5)

	remote_peer.enable_tx
	t1.value
	t2.value
    end

    def test_call_raises
        disable_logging do
            assert_raises(RuntimeError) do
                remote_peer.call(:reply_error, 2)
            end
        end
    end

    def test_call_disconnects
	remote_peer.disable_tx

	remote_peer.transmit(:reply_error, 2)
	sleep(0.5)

        disable_logging do
            Thread.new do
                sleep(0.5)
                remote_peer.enable_tx
            end
            assert_raises(DisconnectedError) { remote_peer.call(:reply, nil, 42) }
        end
    end

    def test_callback
	FlexMock.use do |mock|
	    # Check that nothing is sent while the link is not alive
	    mock.should_receive(:method_called).with(42).once.ordered
	    mock.should_receive(:method_called).with(44).once.ordered
	    mock.should_receive(:method_called).with(43).once.ordered

	    assert_equal(42, remote_peer.call(:reply_with_callback, DRbObject.new(mock), 42))
	end
    end

    def test_recursive_callbacks
        disable_logging do
            assert_raises(DisconnectedError) { remote_peer.call(:recursive_callbacks) }
        end
    end

    def test_synchro_point
	remote_peer.disable_tx
	remote.send_local_peer(:disable_tx)
	FlexMock.use do |mock|
	    remote_peer.transmit(:reply, DRbObject.new(mock), 42)
	    remote_peer.transmit(:reply, DRbObject.new(mock), 21)
	    remote.send_local_peer(:transmit, :reply, DRbObject.new(mock), 42)
	    remote.send_local_peer(:transmit, :reply, DRbObject.new(mock), 21)

	    Thread.current.priority = 10
	    sleep(0.5)
	    mock.should_receive(:method_called).times(4)

	    remote_peer.enable_tx
	    remote.send_local_peer(:enable_tx)
	    remote_peer.synchro_point
	end

    ensure
	Thread.current.priority = 0
    end
end

