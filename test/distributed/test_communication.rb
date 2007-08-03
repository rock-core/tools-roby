require 'test/unit'
require 'roby/distributed'
require 'roby/test/distributed'
require 'flexmock'

class TC_DistributedCommunication < Test::Unit::TestCase
    include Roby
    include Roby::Distributed::Test

    class ConnectionSpace < Roby::Distributed::ConnectionSpace
        def wait_next_discovery
            sleep(0.1)
        end
    end

    class FakePeer < Peer
	def initialize(cs, port)
	    socket = TCPSocket.new('localhost', port)
	    super(cs, socket)
	end
	def connect; end
	attr_predicate :link_alive?, true

	class << self
	    public :new
	end

	attr_reader :remote_server
	def setup(remote)
	    @remote_server    = remote
	    @connection_state = :connected
	    @link_alive       = true
	    @sync = true

	    Roby.execute do
		task.emit :ready
	    end
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

	DRb.stop_service

	remote_process do
	    Roby.logger.progname = "(remote)"
	    front = Class.new do
		attr_accessor :peer_server
		attr_accessor :connection_space

		def initialize
		    @connection_space = ConnectionSpace.new(:ring_discovery => false, :listen_at => REMOTE_PORT)
		    Distributed.state = connection_space
		end

		def setup_peer(remote)
		    sleep(0.1)
		    peer = ObjectSpace.enum_for(:each_object, Peer).find { true }
		    raise "no peer" unless peer

		    class << peer
			attr_predicate :link_alive?, true
		    end

		    peer.instance_eval do
			@remote_server    = remote
			@connection_state = :connected
			@link_alive       = true
			@sync = true
		    end
		    def peer.disconnected!
			@connection_state = :disconnected
		    end

		    peer.local_server.extend FakePeerServerMethods
		    self.peer_server = peer.local_server
		end
	    end.new

	    Roby.control.run :detach => true, :cycle => 0.1
	    Roby.logger.level = Logger::FATAL
	    DRb.start_service REMOTE_SERVER, front
	end
	Roby.logger.progname = "(local)"
	DRb.start_service LOCAL_SERVER
	Roby.control.run :detach => true, :cycle => 0.1

	connection_space = ConnectionSpace.new(:ring_discovery => false, :listen_at => LOCAL_PORT)
	Distributed.state = connection_space
	@remote_peer   = FakePeer.new connection_space, REMOTE_PORT
	@remote_server = remote_peer.local_server
	remote_server.extend FakePeerServerMethods

	remote_front = DRbObject.new_with_uri(REMOTE_SERVER)
	remote_front.setup_peer(DRbObject.new(remote_server))
	@local_server  = remote_front.peer_server
	@local_peer    = local_server.peer_drb_object

	remote_peer.setup(local_server)

	assert(local_peer.connected?)
	assert(remote_peer.connected?)
    end

    def teardown
	remote_peer.connection_space.quit if remote_peer
	local_peer.connection_space.quit  if local_peer
	super 
    end

    def test_transmit
	FlexMock.use do |mock|
	    # Check that nothing is sent while the link is not alive
	    remote_peer.link_alive = false
	    remote_peer.transmit(:reply, DRbObject.new(mock), 42) do |result|
		mock.block_called(result)
	    end

	    remote_peer.transmit(:reply, DRbObject.new(mock), 24)
	    remote_peer.transmit(:reply, DRbObject.new(mock), 24) do |result|
		mock.block_called(result)
	    end

	    mock.should_receive(:link_alive).ordered
	    mock.should_receive(:method_called).with(42).once.ordered(:first_call)
	    mock.should_receive(:method_called).with(24).twice.ordered(:second_calls)
	    mock.should_receive(:block_called).with(42).once.ordered(:second_calls)
	    mock.should_receive(:block_called).with(24).once.ordered

	    mock.link_alive
	    remote_peer.link_alive = true
	    remote_peer.synchro_point
	end
    end

    def test_transmit_error
	FlexMock.use do |mock|
	    remote_peer.link_alive = false
	    remote_peer.transmit(:reply_error, 2) do |result|
		mock.block_called
	    end
	    mock.should_receive(:block_called).never
	    remote_peer.link_alive = true
	    assert_raises(Roby::Distributed::DisconnectedError) { remote_peer.synchro_point }

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
	remote_peer.link_alive = false

	t1 = Thread.new { test_call(42) }
	# wait for the TX thread to notice the new entry in the queue and
	# wake up
	sleep(0.5)

	t2 = Thread.new { test_call(21) }
	# Wait for +t2+ to insert its entry in the TX queue
	sleep(0.5)

	remote_peer.link_alive = true
	t1.value
	t2.value
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
	sleep(0.5)

	Thread.new do
	    sleep(0.5)
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
	assert_raises(DisconnectedError) { remote_peer.call(:recursive_callbacks) }
    end

    def test_synchro_point
	remote_peer.link_alive = false
	local_peer.link_alive = false
	FlexMock.use do |mock|
	    mock.should_receive(:method_called).times(4)
	    remote_peer.transmit(:reply, DRbObject.new(mock), 42)
	    remote_peer.transmit(:reply, DRbObject.new(mock), 21)
	    local_peer.transmit(:reply, DRbObject.new(mock), 42)
	    local_peer.transmit(:reply, DRbObject.new(mock), 21)

	    Thread.current.priority = 10
	    remote_peer.link_alive = true
	    local_peer.link_alive = true
	    remote_peer.synchro_point
	end

    ensure
	Thread.current.priority = 0
    end
end

