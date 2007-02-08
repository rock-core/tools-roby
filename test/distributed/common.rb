require 'test_config'
require 'rinda/rinda'
require 'roby/distributed'

module DistributedTestCommon
    include Rinda
    include Roby
    include Distributed
    include RobyTestCommon

    def plan; Control.instance.plan end

    def setup
	super

	save_collection Distributed.new_neighbours_observers
	Distributed.allow_remote_access Distributed::Peer
	@old_logger_level = Distributed.logger.level
    end
    def teardown
	if remote_peer
	    apply_remote_command
	    
	    if remote_peer.connected?
		remote_peer.disconnect
		assert_doesnt_timeout(5, "watchdog failed") do
		    loop do
			apply_remote_command
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
	    :plan => Control.instance.plan
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

	# we must call #process_events to make sure the ConnectionTask objects
	# are inserted in both plans
	apply_remote_command
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
	    remote.process_events
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

# class DRbObject
#     alias :__call_remote :method_missing
#     def method_missing(name, *args, &block)
# 	unless caller[0] =~ /test/
# 	    STDERR.puts "calling #{name}(#{args.to_s}, &#{block}) from #{caller[0]}"
# 	end
# 	__call_remote(name, *args, &block)
#     end
# end

