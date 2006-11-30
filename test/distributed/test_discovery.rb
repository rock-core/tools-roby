$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'test_config'
require 'mockups/tasks'
require 'roby/distributed/connection_space'
require 'roby/distributed/proxy'

class TC_DistributedDiscovery < Test::Unit::TestCase
    include Roby
    include Roby::Distributed
    include Rinda
    include CommonTestBehaviour

    def assert_has_neighbour(&check)
	Distributed.state.start_neighbour_discovery
	Distributed.state.wait_discovery

	assert(!Distributed.state.discovering?)
	assert(1, Distributed.neighbours.size)
	assert(Distributed.neighbours.find(&check))
    end

    # Test neighbour discovery using a local tuplespace as the neighbour list. This is
    # mainly useful for testing purposes
    def test_centralized_local_discovery
	central_tuplespace = TupleSpace.new

	remote = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	Distributed.state = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	assert_has_neighbour { |n| n.tuplespace == remote }
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
end


