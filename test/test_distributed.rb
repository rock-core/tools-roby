require 'test_config'
require 'roby/distributed/connection_space'

class TC_Distributed < Test::Unit::TestCase
    include Roby
    include Roby::Distributed
    include Rinda

    def setup
	Thread.abort_on_exception = true
    end

    def teardown 
	Distributed.unpublish
	DRb.stop_service if DRb.thread
	stop_remote_process
    end

    attr_reader :remote_pid, :quit_r, :quit_w
    def remote_process
	start_r, start_w= IO.pipe
	@quit_r,  @quit_w = IO.pipe
	@remote_pid = fork do
	    start_r.close
	    yield
	    start_w.write('OK')
	    quit_r.read(2)
	end
	start_w.close
	start_r.read(2)

    ensure
	start_r.close
    end
    
    def stop_remote_process
	if remote_pid
	    quit_w.write('OK') 
	    Process.waitpid(remote_pid)
	end
	@remote_pid = nil
    end

    def assert_has_neighbour(&check)
	Distributed.state.start_neighbour_discovery
	Distributed.state.wait_discovery

	assert(!Distributed.state.discovering?)
	assert(1, Distributed.neighbours.size)
	assert(Distributed.neighbours.find(&check))
    end

    def test_centralized_local_discovery
	central_tuplespace = TupleSpace.new

	remote = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	Distributed.state = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	assert_has_neighbour { |n| n.tuplespace == remote }
    end

    def test_centralized_drb_discovery
	central_tuplespace = TupleSpace.new
	DRb.start_service 'druby://localhost:1245', central_tuplespace

	remote_process do
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
    def test_ringserver_discovery
	remote_process do
	    DRb.start_service
	    Distributed.state = ConnectionSpace.new :period => 0.5, :ring_discovery => true, :ring_broadcast => BROADCAST
	    Distributed.publish :bind => '127.0.0.2'
	end

	DRb.start_service
	Distributed.state = ConnectionSpace.new :period => 0.5, :ring_discovery => true, :ring_broadcast => BROADCAST
	Distributed.publish :bind => '127.0.0.1'

	assert_has_neighbour { |n| n.name == "#{Socket.gethostname}-#{remote_pid}" }
    end

    def test_connection
	central_tuplespace = TupleSpace.new

	remote = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace, :name => "remote"
	local   = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace, :name => 'local'
	Distributed.state = local

	# Initiate the connection from +local+ and check we did ask for
	# connection on +remote+
	local.start_neighbour_discovery(true)
	n_remote = Distributed.neighbours.find { true }
	p_remote = Peer.new(local, n_remote)
	assert_equal(local,  p_remote.keepalive['tuplespace'])
	assert_equal(remote, p_remote.neighbour.tuplespace)
	assert_nothing_raised { remote.read(p_remote.keepalive.value, 0) }
	# The connection is not alive yet since +remote+ does not have
	# finalized the handshake yet
	assert(! p_remote.connected?)
	assert(! p_remote.alive?)

	# After +remote+ has finished neighbour discovery, all connection
	# attempts should have been finalized, so we should have a Peer object
	# for +local+
	remote.start_neighbour_discovery(true)
	p_local = remote.peers.find { |_, p_local| p_local.neighbour.tuplespace == local }
	assert(p_local)
	p_local = p_local.last
	assert_equal(remote, p_local.keepalive['tuplespace'])
	assert_equal(local,  p_local.neighbour.tuplespace)
	assert_nothing_raised { local.read(p_local.keepalive.value, 0) }
	assert(p_local.connected?)
	assert(p_local.alive?)
	# p_remote is still not alive since +local+ does not know the
	# connection is finalized
	assert(! p_remote.alive?)
	assert(! p_remote.connected?)

	# Finalize the connection
	local.start_neighbour_discovery(true)
	assert(p_remote.connected?)
	assert(p_remote.alive?)
    end

    # Establishes a peer to peer connection between two ConnectionSpace objects
    def peer2peer
	central_tuplespace = TupleSpace.new
	remote = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace, :name => "remote",
	    :plan => Plan.new

	local   = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace, :name => 'local',
	    :plan => Plan.new

	local.start_neighbour_discovery(true)
	n_remote = local.neighbours.find { true }
	p_remote = Peer.new(local, n_remote)
	remote.start_neighbour_discovery(true)
	local.start_neighbour_discovery(true)
	p_local = remote.peers.find { true }.last

	return [remote, p_remote, local, p_local]
    end

    def test_query
	remote, p_remote, local, p_local = peer2peer
	assert(p_local.connected?)
	assert(p_remote.connected?)

	mission, subtask = Task.new, Task.new
	mission.realized_by subtask
	remote.plan.insert(mission)

	# Get the remote missions
	r_missions = p_remote.plan.missions
	assert_equal([mission].to_a, r_missions.to_a)

	# Get the remote tasks
	r_missions = p_remote.plan.known_tasks
	assert_equal([mission, subtask].to_set, r_missions.to_set)
    end
end

