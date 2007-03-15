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
		@old_distributed_logger_level = Distributed.logger.level

		timings[:setup] = Time.now

		# Start the GC so that it does not kick in a test. On slow machines, 
		# it can trigger timeouts
		GC.start
		timings[:gc] = Time.now
	    end

	    def teardown
		super

		unless Distributed.peers.empty?
		    Roby.warn "  still referencing #{Distributed.peers.keys}"
		    Distributed.peers.clear
		end

		# This one is a nasty one ...
		# The main plan is the only thing which remains. If we do not reset
		# the cached drb_object, it will be kept in the next test and the forked
		# child will therefore use it ... And it will fail
		plan.instance_eval do
		    @__droby_drb_object__ = nil
		    @__droby_marshalled__ = nil
		end

		if Distributed.state
		    Distributed.state.quit
		    Distributed.state = nil
		end

		timings[:end] = Time.now
	    ensure
		Distributed.logger.level = @old_distributed_logger_level
	    end

	    module RemotePeerSupport
		attr_accessor :testcase

		def process_events; Roby.control.process_events end
		def local_peer; @local_peer ||= Distributed.peer("local") end
		def reset_local_peer; @local_peer = nil end
		def send_local_peer(*args); local_peer.send(*args) end
		def wait_one_cycle; Roby.control.wait_one_cycle end
		def console_logger=(value); testcase.console_logger = value end
		def log_level=(value); Roby.logger.level = value end
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

		remote_process do
		    central_tuplespace = DRbObject.new_with_uri(DISCOVERY_URI)
		    cs = ConnectionSpace.new :ring_discovery => false, 
			:discovery_tuplespace => central_tuplespace, :name => "remote" do |remote|
			    getter = Class.new { def get; DRbObject.new(Distributed.state) end }.new
			    DRb.start_service REMOTE_URI, getter
			end
		    cs.extend RemotePeerSupport
		    cs.testcase = self

		    Distributed.state = cs
		    yield(Distributed.state) if block_given?
		end

		DRb.start_service LOCAL_URI
		@central_tuplespace = DRbObject.new_with_uri(DISCOVERY_URI)
		@remote  = DRbObject.new_with_uri(REMOTE_URI).get
		@local   = ConnectionSpace.new :ring_discovery => false, 
		    :discovery_tuplespace => central_tuplespace, :name => 'local', 
		    :plan => plan

		Distributed.state = local
	    end

	    def setup_connection
		assert(remote_neighbour = local.neighbours.find { true })
		@remote_peer = Peer.new(local, remote_neighbour)

		remote.start_neighbour_discovery(true)
		remote.process_events
		assert(remote.send_local_peer(:connecting?))

		local.start_neighbour_discovery(true)
		process_events
		assert(remote_peer.connected?)

		remote.start_neighbour_discovery(true)
		remote.process_events
		assert(remote.send_local_peer(:connected?))
	    end

	    attr_reader :central_tuplespace, :remote, :remote_peer, :remote_plan, :local

	    # Establishes a peer to peer connection between two ConnectionSpace objects
	    def peer2peer(detached_control = false)
		timings[:starting_peers] = Time.now
		start_peers do |remote|
		    def remote.start_control_thread
			Control.event_processing << Distributed.state.method(:start_neighbour_discovery)
			Roby.control.run :detach => true
		    end
		    yield(remote) if block_given?
		end

		setup_connection
		if detached_control
		    Control.event_processing << Distributed.state.method(:start_neighbour_discovery)
		    Roby.control.run :detach => true
		    remote.start_control_thread
		end
		timings[:started_peers] = Time.now
	    end

	    def process_events
		if Roby.control.thread
		    remote_peer.synchro_point
		    remote.wait_one_cycle
		    Roby.control.wait_one_cycle
		elsif remote_peer && !remote_peer.disconnected?
		    remote.start_neighbour_discovery(true)
		    local.start_neighbour_discovery(true)
		    remote_peer.flush
		    remote.send_local_peer(:flush)
		    Roby::Control.synchronize do
			remote.process_events
			Roby.control.process_events
		    end
		    remote_peer.flush
		    remote.send_local_peer(:flush)
		else
		    super
		end
	    end

	    def remote_task(match)
		result = remote_peer.find_tasks.with_arguments(match).to_a
		assert_equal(1, result.size)
		result.first
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
