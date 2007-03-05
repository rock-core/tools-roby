$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'
require 'flexmock'

class TC_DistributedConnection < Test::Unit::TestCase
    include Rinda
    include Roby
    include Distributed
    include Roby::Distributed::Test

    def setup
	super
	Distributed.allow_remote_access Distributed::Neighbour
    end

    def assert_has_neighbour(&check)
	Distributed.state.start_neighbour_discovery
	Distributed.state.wait_discovery

	assert(!Distributed.state.discovering?)
	assert(1, Distributed.neighbours.size)
	assert(Distributed.neighbours.find(&check))
    end

    def test_peer_flatten_demux_calls
	test_call = [nil, [:test, 1, 2]]
	assert_equal([[test_call, :block, :trace]], Peer.flatten_demux_call([test_call], :block, :trace))

	demux_call = [nil, [:demux, [test_call]]]
	calls = [test_call, demux_call, [nil, [:demux, [demux_call.dup]]]]
	result = [[test_call, :block, :trace]] * 3
	assert_equal(result, Peer.flatten_demux_call(calls, :block, :trace))

	# Rebuild calls as it will be in the send queue
	calls.map! { |c| [c, :block, :trace] } 
	assert_equal(result, Peer.flatten_demux_calls(calls))
    end

    # Test neighbour discovery using a remote central tuplespace as neighbour list
    def test_centralized_drb_discovery
	central_tuplespace = TupleSpace.new
	DRb.start_service 'druby://localhost:1245', central_tuplespace

	remote_pid = remote_process do
	    DRb.stop_service
	    DRb.start_service
	    central_tuplespace = DRbObject.new_with_uri('druby://localhost:1245')

	    Distributed.state = ConnectionSpace.new :ring_discovery => false, 
		:discovery_tuplespace => central_tuplespace
	end
	Distributed.state = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	assert_has_neighbour { |n| n.name == "#{Socket.gethostname}-#{remote_pid}" }
    end

    BROADCAST = (1..10).map { |i| "127.0.0.#{i}" }
    # Test neighbour discovery using UDP for discovery
    def test_ringserver_discovery
	remote_pid = remote_process do
	    DRb.start_service
	    Distributed.state = ConnectionSpace.new :period => 0.5, :ring_discovery => true, :ring_broadcast => BROADCAST
	    Distributed.publish :bind => '127.0.0.2'
	end

	DRb.start_service
	Distributed.state = ConnectionSpace.new :period => 0.5, :ring_discovery => true, :ring_broadcast => BROADCAST
	Distributed.publish :bind => '127.0.0.1'

	assert_has_neighbour { |n| n.name == "#{Socket.gethostname}-#{remote_pid}" }
    end

    # Test establishing peer-to-peer connection between two ConnectionSpace objects
    # Note that #peer2peer is the exact same process
    def test_connect(standalone = true)
	if standalone
	    start_peers

	    notified = []
	    Distributed.new_neighbours_observers << lambda do |cs, n|
		notified << [cs, n]
	    end
	end

	# Initiate the connection from +local+
	local.start_neighbour_discovery(true)
	Control.instance.process_events
	remote_neighbour = Distributed.neighbours.find { true }
	@remote_peer = Peer.new(local, remote_neighbour)
	assert(remote_peer.connecting?)
	assert_raises(ArgumentError) { Peer.new(local, remote_neighbour) }

	# Check we have initialized the connection tuples
	assert_equal(local.tuplespace,  remote_peer.keepalive['tuplespace'])
	assert_equal(remote.tuplespace, remote_peer.neighbour.tuplespace)
	info = { 'kind' => remote_peer.keepalive['kind'],
	    'tuplespace' => remote_peer.keepalive['tuplespace'], 
	    'remote' => remote_peer.keepalive['remote'],
	    'state' => nil }
	assert_nothing_raised { remote.tuplespace.read(info, 0) }

	# The connection is not link_alive yet since +remote+ does not have
	# finalized the handshake yet
	assert(remote_peer.connecting?)
	assert(remote_peer.link_alive?)
	assert(remote_peer.task)

	Control.instance.process_events
	assert(remote_peer.task.running?)

	remote.start_neighbour_discovery(true)
	local_neighbour = remote.send_local_peer(:neighbour)
	local_keepalive = remote.send_local_peer(:keepalive)
	assert_equal(local.tuplespace,  local_neighbour.tuplespace)
	assert_equal(remote.tuplespace, local_keepalive['tuplespace'])
	assert_equal(local.tuplespace,  local_neighbour.tuplespace)
	assert(remote.send_local_peer(:connecting?))
	assert(remote.send_local_peer(:link_alive?))
	assert(!remote.send_local_peer(:task).remote_object.ready?)
	assert(remote_peer.connecting?)
	assert(!remote_peer.task.ready?)

	# Finalize the connection
	local.start_neighbour_discovery(true)
	Control.instance.process_events
	assert(remote_peer.connected?)
	assert(remote_peer.link_alive?)
	assert(remote_peer.task.ready?)
	remote.send_local_peer(:flush)
	remote.process_events
	assert(remote.send_local_peer(:connected?))
	assert(remote.send_local_peer(:link_alive?))
	assert(remote.send_local_peer(:task).remote_object.ready?)

	assert_equal('remote', remote_peer.neighbour.name)
	assert_equal('remote', remote_peer.remote_server.local_name)
	assert_equal('local', remote_peer.remote_server.remote_name)

	if standalone
	    assert_equal(1, notified.size)
	    assert_equal([[local, remote_neighbour]], notified)
	end
    end

    def test_retry
	Roby.logger.level = Logger::FATAL
	peer2peer do |remote|
	    PeerServer.class_eval do
		def error_once
		    unless @pass
			@pass = true
			raise
		    end
		    42
		end
		def next_call
		    84
		end
	    end
	end

	FlexMock.use do |mock|
	    remote_peer.transmit(:error_once) do |result|
		mock.got_result(result)
	    end
	    remote_peer.transmit(:next_call) do |result|
		mock.next_call(result)
	    end
	    mock.should_receive(:got_result).with(42).once.ordered
	    mock.should_receive(:next_call).with(84).once.ordered
	    process_events
	end
    end

    def test_callbacks
	peer2peer do |remote|
	    PeerServer.class_eval do
		def call_back
		    peer.callback(:called_back, 1)
		    peer.callback(:called_back, 2)
		    42
		end
		def next_call; 84 end
	    end
	end

	FlexMock.use do |mock|
	    remote_peer.synchronize do
		remote_peer.local.singleton_class.class_eval do
		    define_method(:called_back) do |arg|
			mock.called_back(arg)
		    end
		end

		remote_peer.transmit(:call_back) do |result|
		    mock.processed_callback(42)
		end
		remote_peer.transmit(:next_call) do |result|
		    mock.processed_next_call(84)
		end

		mock.should_receive(:called_back).with(1).once.ordered
		mock.should_receive(:called_back).with(2).once.ordered
		mock.should_receive(:processed_callback).with(42).once.ordered
		mock.should_receive(:processed_next_call).with(84).once.ordered
	    end
	    process_events
	end
    end

    # Test the normal disconnection process
    def test_disconnect
	peer2peer

	Control.instance.process_events
	assert(remote_peer.task.ready?)

	remote_peer.disconnect
	assert(remote_peer.disconnecting?)
	# check that the 'disconnecting' status is kept across discoveries
	local.start_neighbour_discovery(true)
	assert(remote_peer.disconnecting?)

	remote.start_neighbour_discovery(true)
	assert(remote.send_local_peer(:disconnected?))
	local.start_neighbour_discovery(true)
	assert(remote_peer.disconnected?)
	remote.reset_local_peer

	# Make sure that we can reconnect
	test_connect(false)
    end

    # Tests that the remote peer disconnects if #demux raises DisconnectedError
    def test_automatic_disconnect
	# Temporarily raise the logging level since we will generate a communication error
	Roby.logger.level = Logger::DEBUG
	peer2peer do |remote|
	    class << remote
		include Test::Unit::Assertions
		def assert_demux_raises
		    peer = peers.find { true }[1]
		    peer.transmit(:whatever)
		    peer.flush rescue nil
		end
	    end
	end

	remote_peer.disconnect
	remote.assert_demux_raises
	remote.start_neighbour_discovery(true)
	assert(remote.send_local_peer(:disconnected?))

	local.start_neighbour_discovery(true)
	assert(remote_peer.disconnected?)
	remote.reset_local_peer

	# Make sure that we can reconnect
	test_connect(false)
    end
end

