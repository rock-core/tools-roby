$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'distributed/common'
require 'mockups/tasks'
require 'roby/distributed/connection_space'
require 'roby/distributed/proxy'

class TC_DistributedConnection < Test::Unit::TestCase
    include Rinda
    include Roby
    include Distributed
    include DistributedTestCommon

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

    # Test neighbour discovery using a local tuplespace as the neighbour list. This is
    # mainly useful for testing purposes
    def test_centralized_local_discovery
	central_tuplespace = TupleSpace.new

	remote = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	Distributed.state = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	assert_has_neighbour { |n| n.tuplespace == remote.tuplespace }
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

	# Initiate the connection from +local+ and check we did ask for
	# connection on +remote+
	local.start_neighbour_discovery(true)
	Control.instance.process_events
	n_remote = Distributed.neighbours.find { true }
	handler_called = false
	p_remote = Peer.new(local, n_remote) { handler_called = true }
	assert_raises(ArgumentError) { Peer.new(local, n_remote) }
	assert_equal(local.tuplespace,  p_remote.keepalive['tuplespace'])
	assert_equal(remote.tuplespace, p_remote.neighbour.tuplespace)
	info = { 'kind' => p_remote.keepalive['kind'],
	    'tuplespace' => p_remote.keepalive['tuplespace'], 
	    'remote' => p_remote.keepalive['remote'],
	    'state' => nil }
	assert_nothing_raised { remote.tuplespace.read(info, 0) }
	# The connection is not link_alive yet since +remote+ does not have
	# finalized the handshake yet
	assert(! p_remote.connected?)
	assert(p_remote.link_alive?)
	assert(p_remote.task)
	Control.instance.process_events
	assert(p_remote.task.running?)

	# After +remote+ has finished neighbour discovery, all connection
	# attempts should have been finalized, so we should have a Peer object
	# for +local+
	remote.start_neighbour_discovery(true)
	Control.instance.process_events
	p_local = remote.peers.find { true }.last
	assert_equal(local.tuplespace, p_local.neighbour.tuplespace)
	assert_equal(remote.tuplespace, p_local.keepalive['tuplespace'])
	assert_equal(local.tuplespace,  p_local.neighbour.tuplespace)
	assert_nothing_raised { local.tuplespace.read(p_local.keepalive.value, 0) }

	remote.process_events
	assert(p_local.connected?)
	assert(p_local.link_alive?)
	assert(p_local.task.remote_object.ready?)
	# p_remote is still not link_alive since +local+ does not know the
	# connection is finalized
	assert(p_remote.link_alive?)
	assert(! p_remote.connected?)
	assert(! p_remote.task.ready?)

	# Finalize the connection
	local.start_neighbour_discovery(true)
	Control.instance.process_events
	assert(p_remote.connected?)
	assert(handler_called)
	assert(p_remote.link_alive?)
	assert(p_remote.task.ready?)

	assert_equal('remote', p_remote.neighbour.name)
	assert_equal('remote', p_remote.remote_server.local_name)
	assert_equal('local', p_remote.remote_server.remote_name)

	if standalone
	    assert_equal(1, notified.size)
	    assert_equal([[local, n_remote]], notified)
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
	assert(!local_peer.connected?)

	local.start_neighbour_discovery(true)
	assert(!remote_peer.connected?)

	# Make sure that we can reconnect
	test_connect(false)
    end

    # Tests that the remote peer disconnects if #demux raises DisconnectedError
    def test_automatic_disconnect

	peer2peer do |remote|
	    class << remote
		include Test::Unit::Assertions
		def assert_demux_raises
		    peer = peers.find { true }[1]
		    peer.transmit(:whatever)
		    peer.flush
		end
	    end
	end
	remote_peer.disconnect
	remote.assert_demux_raises
	assert(!local_peer.connected?)

	local.start_neighbour_discovery(true)
	assert(!remote_peer.connected?)

	# Make sure that we can reconnect
	test_connect(false)
    end
end

