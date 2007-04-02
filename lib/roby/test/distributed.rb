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
		    @__droby_remote_id__ = nil
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

	    # Start a central discovery service, a remote connectionspace and a local
	    # connection space. It yields the remote connection space *in the forked
	    # child* if a block is given.
	    def start_peers
		DRb.stop_service
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
		@remote_peer = Peer.initiate_connection(local, remote_neighbour)

		process_events
		assert(remote_peer.connected?)
		process_events
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
		    remote.wait_one_cycle
		    Roby.control.wait_one_cycle
		elsif remote_peer && !remote_peer.disconnected?
		    Roby::Control.synchronize do
			remote.process_events
			Roby.control.process_events
		    end
		else
		    super
		end
	    end

	    def remote_task(match)
		found = nil
		remote_peer.find_tasks.with_arguments(match).each do |task|
		    assert(!found)
		    found = if block_given? then yield(task)
			    else task
			    end
		end
		found
	    end
	    def subscribe_task(match)
		remote_task(match) do |task|
		    remote_peer.subscribe(task)
		    task
		end
	    end

	    def remote_server(&block)
		DRb.stop_service
		remote_process do
		    server = Class.new do
			class_eval(&block)
		    end.new
		    DRb.start_service REMOTE_URI, server
		end

		DRb.start_service LOCAL_URI
		DRbObject.new_with_uri(REMOTE_URI)
	    end
	end
    end
end
