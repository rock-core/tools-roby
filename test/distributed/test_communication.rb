require 'test/unit'
require 'roby/distributed'
require 'roby/test/distributed'
require 'flexmock'

class TC_DistributedCommunication < Test::Unit::TestCase
    include Roby::Distributed::Test
    include Roby

    class FakePeer < Peer
	class ConnectionSpace
	    attr_predicate :send_running?
	    def wait_discovery
		@send_running = true
		sleep(0.1)
	    end
	end

	def initialize(name)
	    neighbour = Roby::Distributed::Neighbour.new(name, nil)
	    super(ConnectionSpace.new, neighbour)
	end
	def connect; end
	attr_predicate :link_alive?, true

	class << self
	    public :new
	end

	attr_reader :remote_server
	def setup(remote)
	    @remote_server = remote
	    @connection_state = :connected
	    @send_queue  = Roby::Distributed::CommunicationQueue.new
	    @send_thread = Thread.new(&method(:communication_loop))
	    @link_alive = true
	end

	def disconnected!
	    @connection_state = nil
	end
    end

    attr_reader :local_peer, :remote_peer
    attr_reader :local_server, :remote_server

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
	    peer.link_alive = false
	    mock.method_called(value)
	    peer.transmit(:reply, mock, value + 1)
	    mock.method_called(value + 2)
	    peer.link_alive = true
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

	remote_process do
	    Roby.logger.level = Logger::FATAL
	    peer = FakePeer.new 'local'
	    DRb.start_service REMOTE_URI, peer.local
	    peer.local.extend FakePeerServerMethods
	end

	@remote_peer = FakePeer.new 'remote'
	DRb.start_service LOCAL_URI, remote_peer.local
	@remote_server = remote_peer.local
	remote_server.extend FakePeerServerMethods

	@local_server  = DRbObject.new_with_uri(REMOTE_URI)
	@local_peer    = local_server.peer_drb_object

	remote_peer.setup(local_server)
	local_peer.setup(DRbObject.new(remote_server))

	assert(local_peer.connected?)
	assert(remote_peer.connected?)
    end

    def test_communication_queue
	queue = Roby::Distributed::CommunicationQueue.new
	assert(queue.empty?)

	queue.push 42
	assert(!queue.empty?)
	assert_equal([42], queue.get)
	assert(queue.empty?)

	queue.concat([42])
	queue.concat([84, 21])
	assert_equal([42, 84, 21], queue.get)
	assert(queue.empty?)
	assert_equal([], queue.get(true))
    end

    def test_transmit
	FlexMock.use do |mock|
	    # Check that nothing is sent while the link is not alive
	    remote_peer.link_alive = false
	    remote_peer.transmit(:reply, DRbObject.new(mock), 42) do |result|
		mock.block_called(result)
	    end
	    assert(remote_peer.sending?)

	    remote_peer.transmit(:reply, DRbObject.new(mock), 24)
	    assert(remote_peer.sending?)

	    mock.should_receive(:link_alive).ordered
	    mock.should_receive(:method_called).with(42).once.ordered
	    mock.should_receive(:method_called).with(24).once.ordered
	    mock.should_receive(:block_called).with(42).once.ordered

	    mock.link_alive
	    remote_peer.link_alive = true
	    remote_peer.flush
	    assert(!remote_peer.sending?)
	    assert(remote_peer.send_queue.empty?)
	end
    end

    def test_transmit_error
	Roby.logger.level = Logger::FATAL
	FlexMock.use do |mock|
	    remote_peer.link_alive = false
	    remote_peer.transmit(:reply_error, 2) do |result|
		mock.block_called
	    end
	    mock.should_receive(:block_called).never
	    remote_peer.link_alive = true
	    assert_raises(RuntimeError) { remote_peer.flush }

	    assert(!remote_peer.connected?)
	end
    end
    
    def test_call(value = 42)
	FlexMock.use do |mock|
	    # Check that nothing is sent while the link is not alive
	    mock.should_receive(:method_called).with(value).once
	    assert_equal(value, remote_peer.call(:reply, DRbObject.new(mock), value))
	    assert(!remote_peer.sending?)
	    assert(remote_peer.send_queue.empty?)
	end
    end

    def test_concurrent_calls
	remote_peer.link_alive = false

	t1 = Thread.new { test_call(42) }
	loop do
	    # wait for the TX thread to notice the new entry in the queue and
	    # wake up
	    break if remote_peer.connection_space.send_running?
	    sleep(0.1)
	end

	t2 = Thread.new { test_call(21) }
	loop do
	    # Wait for +t2+ to insert its entry in the TX queue
	    break if remote_peer.send_queue.contents.size == 1
	    sleep(0.1)
	end

	remote_peer.link_alive = true
	t1.value
	t2.value
    end

    def test_flush_raises
	Roby.logger.level = Logger::FATAL
	remote_peer.link_alive = false
	remote_peer.transmit(:reply_error, 2)
	t = Thread.current
	Thread.new do
	    loop do
		break if t.stop?
		sleep 0.1
	    end
	    remote_peer.link_alive = true
	end
	assert_raises(RuntimeError) { remote_peer.flush }
    end

    def test_call_raises
	Roby.logger.level = Logger::FATAL
	assert_raises(RuntimeError) do
	    remote_peer.call(:reply_error, 2)
	end
    end

    def test_call_disconnects
	Roby.logger.level = Logger::FATAL
	remote_peer.link_alive = false

	remote_peer.transmit(:reply_error, 2)
	loop do
	    # wait for the TX thread to notice the new entry in the queue and
	    # wake up
	    break if remote_peer.connection_space.send_running?
	    sleep(0.1)
	end

	Thread.new do
	    loop do
		# Wait for the call to insert its entry in the TX queue
		break if remote_peer.send_queue.contents.size == 1
		sleep(0.1)
	    end
	    remote_peer.link_alive = true
	end
	assert_raises(DisconnectedError) { remote_peer.call(:reply, nil, 42) }
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
	Roby.logger.level = Logger::FATAL
	assert_raises(RecursiveCallbacksError) { remote_peer.call(:recursive_callbacks) }
    end

    def test_synchro_point
	remote_peer.link_alive = false
	local_peer.link_alive = false
	remote_peer.transmit(:reply, nil, 42)
	remote_peer.transmit(:reply, nil, 21)
	local_peer.transmit(:reply, nil, 42)
	local_peer.transmit(:reply, nil, 21)

	Thread.current.priority = 10
	remote_peer.link_alive = true
	local_peer.link_alive = true
	remote_peer.synchro_point
	assert(remote_peer.send_queue.empty?)

    ensure
	Thread.current.priority = 0
    end
end

