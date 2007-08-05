$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'
require 'flexmock'

class TC_DistributedConnection < Test::Unit::TestCase
    include Rinda
    include Roby
    include Distributed
    include Roby::Distributed::Test

    def assert_has_neighbour(&check)
	Distributed.state.start_neighbour_discovery
	Distributed.state.wait_discovery

	assert(!Distributed.state.discovering?)
	assert(1, Distributed.neighbours.size)
	assert(Distributed.neighbours.find(&check), Distributed.neighbours.map { |n| [n.name, n.remote_id] }.to_s)
    end

    # Test neighbour discovery using a remote central tuplespace as neighbour list
    def test_centralized_drb_discovery
	DRb.stop_service

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
	DRb.stop_service

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
	    start_peers(true)

	    notified = []
	    Distributed.on_neighbour do |n|
		notified << n
	    end
	end

	assert(local.discovery_thread)

	# Initiate the connection from +local+
	remote_neighbour = Distributed.neighbours.find { true }
	Roby.execute do
	    did_yield = nil
	    Peer.initiate_connection(local, remote_neighbour) do |did_yield|
	    end

	    # Wait for the remote peer to take into account the fact that we
	    # try connecting
	    Distributed.state.synchronize do
		remote_id = remote_neighbour.remote_id
		assert(Distributed.state.pending_connections[remote_id] ||
		       Distributed.state.peers[remote_id])
	    end

	    sleep(1)
	    Distributed.state.synchronize do
		remote_id = remote_neighbour.remote_id
		assert(@remote_peer = Distributed.state.peers[remote_id], Distributed.state.peers)
		assert_equal(remote_peer, did_yield)
	    end
	    assert(remote_peer.connected?)
	    assert(remote.send_local_peer(:connected?))
	    assert(remote_peer.link_alive?)
	    assert(remote.send_local_peer(:link_alive?))

	    did_yield = nil
	    Peer.initiate_connection(local, remote_neighbour) do |did_yield|
	    end
	    assert_equal(remote_peer, did_yield)
	end

	Roby.control.wait_one_cycle
	assert(remote_peer.task.running?)
	#assert_raises(ArgumentError) { Peer.initiate_connection(local, remote_neighbour) }
	assert(remote_peer.link_alive?)

	remote_peer.synchro_point
	assert(remote_peer.connected?)
	assert(remote_peer.task.ready?)

	assert_equal('remote', remote_peer.remote_name)
	assert_equal('remote', remote_peer.local_server.remote_name)
	assert_equal('local', remote_peer.local_server.local_name)

	if standalone
	    assert_equal(1, notified.size)
	    assert_equal([remote_neighbour], notified)
	end
    end

    def test_concurrent_connection
	Roby.logger.level = Logger::DEBUG
	start_peers(true) do |remote|
	    class << remote
		def find_neighbour
		    @neighbour = Roby::Distributed.neighbours.find { true }
		end
		def connect
		    Roby::Distributed::Peer.initiate_connection(Roby::Distributed.state, @neighbour) do 
			@callback_called ||= 0
			@callback_called += 1
		    end
		    nil
		end

		attr_reader :callback_called
		def peer_objects
		    ObjectSpace.enum_for(:each_object, Roby::Distributed::Peer).to_a.size
		end
	    end
	end

	sleep(0.5)
	assert(remote.find_neighbour)
	assert(remote_neighbour = Distributed.neighbours.find { true })

	remote.connect
	remote.connect

	callback_called = 0
	2.times do
	    Peer.initiate_connection(local, remote_neighbour) do
		callback_called += 1
	    end
	end
	sleep(1)

	assert_equal(2, callback_called)
	assert_equal(2, remote.callback_called)
	assert_equal(1, remote.peer_objects)
	assert_equal(1, ObjectSpace.enum_for(:each_object, Distributed::Peer).to_a.size)
    end

    # Test the normal disconnection process
    def test_disconnect
	peer2peer(true) do |remote|
	    def remote.peers_empty?; Distributed.peers.empty? end
	end

	Roby.control.wait_one_cycle
	assert(remote_peer.task.ready?)

	remote_peer.disconnect
	assert(remote_peer.disconnecting?)
	process_events
	remote.process_events

	assert(remote_peer.disconnected?)
	remote.send_local_peer(:disconnected?)

	assert(Distributed.peers.empty?)
	assert(remote.peers_empty?)
	remote.reset_local_peer

	# Make sure that we can reconnect
	test_connect(false)
    end

    # Tests that the remote peer disconnects if #demux raises DisconnectedError
    def test_disconnect_on_error
	Roby.logger.level = Logger::FATAL
	peer2peer(true) do |remote|
	    class << remote
		include Test::Unit::Assertions
		def assert_demux_raises
		    peer = peers.find { true }[1]
		    peer.transmit(:whatever)
		    peer.synchro_point rescue nil
		end
	    end
	end

	remote_peer.disconnect
	remote.assert_demux_raises
	assert(remote.send_local_peer(:disconnected?))

	assert(remote_peer.disconnected?)
	remote.reset_local_peer

	# Make sure that we can reconnect
	test_connect(false)
    end

    def test_socket_reconnect
	peer2peer(true)
	Distributed.state.synchronize do
	    remote_peer.socket.close
	    assert(!remote_peer.link_alive?)
	end

	sleep(1)
	assert(!remote_peer.socket.closed?)
	assert(remote_peer.connected?)
	assert(remote_peer.link_alive?)
	assert(remote.send_local_peer(:connected?))
	assert(remote.send_local_peer(:link_alive?))
    end

    def test_abort_connection
	peer2peer(true)
	remote_peer.disconnected!

	sleep(1)
	assert(remote_peer.socket.closed?)
	assert(!remote_peer.connected?)
	assert(!remote.send_local_peer(:connected?))
    end
end

