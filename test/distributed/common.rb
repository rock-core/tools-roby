require 'test_config'
require 'rinda/rinda'
require 'roby/distributed/connection_space'
require 'roby/distributed/proxy'

module DistributedTestCommon
    include Rinda
    include Roby
    include Roby::Distributed
    include RobyTestCommon

    attr_reader :plan
    def setup
	super

	save_collection Roby::Distributed.new_neighbours_observers
	Roby::Distributed.allow_remote_access Roby::Distributed::Peer
	@plan = Plan.new
	@old_logger_level = Roby::Distributed.logger.level
    end
    def teardown
	Roby::Distributed.logger.level = @old_logger_level

	if remote_peer
	    Control.instance.process_events
	    apply_remote_command
	end
	@remote_peer = nil
	Roby::Distributed.new_neighbours.clear

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
	    DRb.start_service DISCOVERY_URI, TupleSpace.new
	end

	remote_process do
	    central_tuplespace = DRbObject.new_with_uri(DISCOVERY_URI)
	    cs = ConnectionSpace.new :ring_discovery => false, 
		:discovery_tuplespace => central_tuplespace, :name => "remote",
		:plan => Plan.new, :max_allowed_errors => 1 do |remote|

		getter = Class.new { def get; DRbObject.new(Distributed.state) end }.new
		DRb.start_service REMOTE_URI, getter
	    end
	    def cs.process_events; Control.instance.process_events end

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
	local.start_neighbour_discovery(true)
	n_remote = local.neighbours.find { true }
	remote_peer = Peer.new(local, n_remote)
	remote.start_neighbour_discovery(true)
	local_peer = remote.peers.find { true }.last
	local.start_neighbour_discovery(true)

	assert(local_peer.connected?)
	assert(remote_peer.connected?)

	remote_plan = remote_peer.plan

	@remote, @remote_peer, @remote_plan, @local, @local_peer =
	    remote, remote_peer, remote_plan, local, local_peer
    end

    attr_reader :central_tuplespace, :remote, :remote_peer, :remote_plan, :local, :local_peer

    # Establishes a peer to peer connection between two ConnectionSpace objects
    def peer2peer(&block)
	start_peers(&block)
	setup_connection
    end

    def apply_remote_command
	# flush the command queue
	loop do
	    did_something = remote_peer.flush
	    remote.start_neighbour_discovery(true)
	    did_something ||= local_peer.flush
	    local.start_neighbour_discovery(true)
	    Control.instance.process_events
	    break unless did_something
	end
	yield if block_given?
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


