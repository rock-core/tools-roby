require 'test_config'
require 'roby/distributed/discovery'

class TC_Distributed < Test::Unit::TestCase
    include Roby
    include Roby::Distributed
    include Rinda

    def setup
	Thread.abort_on_exception = true
    end

    def teardown 
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
	here   = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace, :name => 'here'

	Distributed.state = here
	here.start_neighbour_discovery(true)

	n_remote = Distributed.neighbours.find { true }
	p_remote = Peer.new(here, n_remote)
	assert(! p_remote.alive?)
	assert(! p_remote.connected?)
	assert_equal(here, p_remote.keepalive['tuplespace'])
	assert_equal(remote, p_remote.neighbour.tuplespace)
	assert_nothing_raised { remote.read(p_remote.keepalive.value, 0) }

	remote.start_neighbour_discovery(true)
	p_here = remote.peers.find { |_, p_here| p_here.neighbour.tuplespace == here }
	assert(p_here)
	p_here = p_here.last
	assert_equal(remote, p_here.keepalive['tuplespace'])
	assert_equal(here, p_here.neighbour.tuplespace)
	assert_nothing_raised { here.read(p_here.keepalive.value, 0) }
	assert(p_here.connected?)
	assert(p_here.alive?)
	assert(! p_remote.alive?)
	assert(! p_remote.connected?)

	here.start_neighbour_discovery(true)
	assert(p_remote.connected?)
	assert(p_remote.alive?)
    end
end


