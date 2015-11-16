require 'roby/test/distributed'
require 'roby/tasks/simple'

class TC_DistributedConnection < Minitest::Test
    include Rinda
    include Roby
    include Distributed
    include Roby::Distributed::Test

    def assert_has_neighbour(&check)
	Distributed.state.start_neighbour_discovery
	Distributed.state.wait_discovery

	assert(!Distributed.state.discovering?)
	assert(1, local.neighbours.size)
	assert(local.neighbours.find(&check), local.neighbours.map { |n| [n.name, n.remote_id] }.to_s)
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

	    Distributed.state = ConnectionSpace.new ring_discovery: false, 
		discovery_tuplespace: central_tuplespace, plan: plan
	end
	@local = ConnectionSpace.new ring_discovery: false, 
	    discovery_tuplespace: central_tuplespace, plan: plan
        Distributed.state = local
	assert_has_neighbour { |n| n.name == "#{Socket.gethostname}-#{remote_pid}" }
    end

    BROADCAST = (1..10).map { |i| "127.0.0.#{i}" }
    # Test neighbour discovery using UDP for discovery
    def test_ringserver_discovery
	DRb.stop_service

	remote_pid = remote_process do
	    DRb.start_service
	    Distributed.state = ConnectionSpace.new period: 0.5, ring_discovery: true, ring_broadcast: BROADCAST, plan: plan
	    Distributed.publish bind: '127.0.0.2'
	end

	DRb.start_service
        @local = ConnectionSpace.new period: 0.5, ring_discovery: true, ring_broadcast: BROADCAST, plan: plan
	Distributed.state = local
	Distributed.publish bind: '127.0.0.1'

	assert_has_neighbour { |n| n.name == "#{Socket.gethostname}-#{remote_pid}" }
    end

    # Test establishing peer-to-peer connection between two ConnectionSpace objects
    # Note that #peer2peer is the exact same process
    def test_connect(standalone = true)
	if standalone
	    start_peers

	    notified = []
	    local.on_neighbour do |n|
		notified << n
	    end
	end

	assert(local.discovery_thread)

	# Initiate the connection from +local+
	remote_neighbour = local.neighbours.find { true }
	engine.execute do
	    did_yield = nil
	    Peer.initiate_connection(local, remote_neighbour) do |did_yield|
	    end

	    # Wait for the remote peer to take into account the fact that we
	    # try connecting
	    local.synchronize do
		remote_id = remote_neighbour.remote_id
		assert(local.pending_connections[remote_id] ||
		       local.peers[remote_id])
	    end

	    sleep(1)
	    local.synchronize do
		remote_id = remote_neighbour.remote_id
		assert(@remote_peer = local.peers[remote_id], local.peers)
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
	    assert_equal(remote_peer, Peer.connect(remote_neighbour))
	end

	engine.wait_one_cycle
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

    def test_synchronous_connect
	start_peers do |remote|
	    def remote.connected?
		local_peer.connected?
	    end
	end

	sleep(0.5)
	assert(remote_neighbour = Distributed.neighbours.find { true })
	assert(remote_peer = Peer.connect(remote_neighbour))

	assert_kind_of(Distributed::Peer, remote_peer)
	assert(remote.connected?)
	assert(remote_peer.connected?)
    end

    def test_concurrent_connection
	GC.disable
	start_peers do |remote|
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
		    peer_objects = ObjectSpace.enum_for(:each_object, Roby::Distributed::Peer).to_a
		    [Roby::Distributed.peers.keys.size, peer_objects.size]
		end
	    end
	end

	sleep(0.5)
	assert(remote.find_neighbour)
	assert(remote_neighbour = Distributed.neighbours.find { true })

	# We want to check that a concurrent connection creates only one Peer
	# object. Still, we have to take into account that the remote peer is a
	# fork of ourselves, and as such inherits the Peer objects this process
	# has in its ObjectSpace (like the leftovers of other tests)
	registered_peer_count, initial_remote_peer_count = remote.peer_objects
	assert_equal(0, registered_peer_count)
	registered_peer_count, initial_local_peer_count = Distributed.peers.keys.size,
	    ObjectSpace.enum_for(:each_object, Distributed::Peer).to_a.size
	assert_equal(0, registered_peer_count)

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
	assert_equal([1, initial_remote_peer_count + 1], remote.peer_objects)
	assert_equal(1, Distributed.peers.keys.size)
	assert_equal(initial_local_peer_count + 1, ObjectSpace.enum_for(:each_object, Distributed::Peer).to_a.size)
    ensure
	GC.enable
    end

    # Test the normal disconnection process
    def test_disconnect
	peer2peer do |remote|
	    def remote.peers_empty?; Distributed.peers.empty? end
	end

	engine.wait_one_cycle
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
	peer2peer do |remote|
	    class << remote
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
	peer2peer
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

    def test_remote_dies
	peer2peer
	Process.kill('KILL', remote_processes[1][0])

	sleep(1)
	assert(remote_peer.disconnected?)
    end


    def test_abort_connection
	peer2peer
	remote_peer.disconnected!

	sleep(1)
	assert(remote_peer.socket.closed?)
	assert(!remote_peer.connected?)
	assert(!remote.send_local_peer(:connected?))
    end
end

