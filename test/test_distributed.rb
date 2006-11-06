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

    def test_centralized_discovery
	central_tuplespace = TupleSpace.new

	Distributed.state = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	host2 = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace

	Distributed.state.start_neighbour_discovery
	Distributed.state.wait_discovery
	assert(Distributed.neighbours.find { |n| n[0] == host2 })
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

	Distributed.state.start_neighbour_discovery
	Distributed.state.wait_discovery
	assert(Distributed.neighbours.find { |n| n[1] == "#{Socket.gethostname}-#{remote_pid}" })
    end

    def test_connection
    end
end


