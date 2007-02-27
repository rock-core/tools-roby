require 'roby/test/common'
require 'roby/distributed'

module Roby
    module Distributed
	module Test
	    include ::Roby::Test
	    include ::Roby::Distributed

	    def setup
		super

		save_collection Distributed.new_neighbours_observers
		Distributed.allow_remote_access Distributed::Peer
		@old_logger_level = Distributed.logger.level

		# Start the GC so that it does not kick in a test. On slow machines, 
		# it can trigger timeouts
		GC.start
	    end

	    def teardown
		if remote_peer
		    process_events

		    if remote_peer.connected?
			remote_peer.disconnect
			assert_doesnt_timeout(5, "watchdog failed") do
			    loop do
				process_events
				break if remote_peer.task.event(:stop).happened?
				sleep(0.2)
			    end
			end

		    end
		end
		@remote_peer = nil

		if Distributed.state
		    Distributed.state.quit
		    Distributed.state = nil
		end

	    ensure
		Distributed.logger.level = @old_logger_level
		super
	    end

	    BASE_PORT     = 1245
	    DISCOVERY_URI = "roby://localhost:#{BASE_PORT}"
	    REMOTE_URI    = "roby://localhost:#{BASE_PORT + 1}"
	    LOCAL_URI     = "roby://localhost:#{BASE_PORT + 2}"
	    # Start a central discovery service, a remote connectionspace and a local
	    # connection space. It yields the remote connection space *in the forked
	    # child* if a block is given.
	    def start_peers
		remote_process do
		    DRb.start_service DISCOVERY_URI, Rinda::TupleSpace.new
		end
		sleep(0.5)

		remote_process do
		    central_tuplespace = DRbObject.new_with_uri(DISCOVERY_URI)
		    cs = ConnectionSpace.new :ring_discovery => false, 
			:discovery_tuplespace => central_tuplespace, :name => "remote",
			:plan => Plan.new, :max_allowed_errors => 1 do |remote|
			    getter = Class.new { def get; DRbObject.new(Distributed.state) end }.new
			    DRb.start_service REMOTE_URI, getter
			end
		    def cs.process_events; Control.instance.process_events end
		    def cs.local_peer; @local_peer ||= Distributed.peer("local") end

		    Distributed.state = cs
		    yield(Distributed.state) if block_given?
		end

		DRb.start_service LOCAL_URI
		@central_tuplespace = DRbObject.new_with_uri(DISCOVERY_URI)
		@remote  = DRbObject.new_with_uri(REMOTE_URI).get
		@local   = ConnectionSpace.new :ring_discovery => false, 
		    :discovery_tuplespace => central_tuplespace, :name => 'local',
		    :max_allowed_errors => 1,
		    :plan => plan

		Distributed.state = local
	    end

	    def setup_connection
		assert(remote_neighbour = local.neighbours.find { true })
		@remote_peer = Peer.new(local, remote_neighbour)

		remote.start_neighbour_discovery(true)
		remote.process_events
		assert(@local_peer = remote.peers.find { true }.last)
		assert(local_peer.connected?)

		local.start_neighbour_discovery(true)
		process_events
		assert(remote_peer.connected?)

		@remote_plan = remote_peer.plan
	    end

	    attr_reader :central_tuplespace, :remote, :remote_peer, :remote_plan, :local, :local_peer

	    # Establishes a peer to peer connection between two ConnectionSpace objects
	    def peer2peer(&block)
		start_peers(&block)
		setup_connection
	    end

	    def process_events
		if remote
		    remote.start_neighbour_discovery(true)
		    local.start_neighbour_discovery(true)
		    remote_peer.flush
		    local_peer.flush
		    remote.process_events
		    Control.instance.process_events
		    remote_peer.flush
		    local_peer.flush
		else
		    super
		end
	    end

	    def remote_task(match)
		result = remote_peer.plan.known_tasks.find do |t|
		    t.arguments.slice(*match.keys) == match
		end
		assert(result, remote_peer.plan.known_tasks)
		result
	    end

	    def remote_server(&block)
		remote_process do
		    server = Class.new do
			class_eval(&block)
		    end.new
		    DRb.start_service 'roby://localhost:1245', server
		end
		DRb.start_service 'roby://localhost:1246'
		DRbObject.new_with_uri('roby://localhost:1245')
	    end
	end
    end
end
