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
	    start_peers

	    notified = []
	    Distributed.new_neighbours_observers << lambda do |cs, n|
		notified << [cs, n]
	    end
	end

	# Initiate the connection from +local+
	local.start_neighbour_discovery(true)
	remote_neighbour = Distributed.neighbours.find { true }
	@remote_peer     = Peer.initiate_connection(local, remote_neighbour)
	assert(remote_peer.connecting?)
	assert(remote.send_local_peer(:connecting?))
	assert(remote_peer.link_alive?)
	assert(remote.send_local_peer(:link_alive?))

	Control.instance.process_events
	assert(remote_peer.task.running?)

	assert_raises(ArgumentError) { Peer.initiate_connection(local, remote_neighbour) }

	remote_peer.flush
	remote.send_local_peer(:flush)
	assert(remote_peer.connected?)
	assert(remote_peer.task.ready?)

	assert_equal('remote', remote_peer.neighbour.name)
	assert_equal('remote', remote_peer.remote_server.local_name)
	assert_equal('local', remote_peer.remote_server.remote_name)

	if standalone
	    assert_equal(1, notified.size)
	    assert_equal([[local, remote_neighbour]], notified)
	end
    end

    # Test the normal disconnection process
    def test_disconnect
	peer2peer do |remote|
	    def remote.peers_empty?; Distributed.peers.empty? end
	end
	Roby.logger.level = Logger::INFO

	Control.instance.process_events
	assert(remote_peer.task.ready?)

	remote_peer.disconnect
	assert(remote_peer.disconnecting?)
	remote_peer.flush
	remote.send_local_peer(:flush)
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

