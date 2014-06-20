require 'roby/test/self'
require 'roby/distributed'

module Roby
    module Distributed
	module Test
	    include ::Roby::Test::Self
	    include ::Roby::Distributed

	    def setup
		super

		@old_distributed_logger_level = Distributed.logger.level

		timings[:setup] = Time.now

		# Start the GC so that it does not kick in a test. On slow machines, 
		# it can trigger timeouts
		GC.start
		timings[:gc] = Time.now
	    end

	    def teardown
		begin
		    if remote && remote.respond_to?(:cleanup)
			remote.cleanup
		    end
		rescue DRb::DRbConnError
		end

		super

		unless Distributed.peers.empty?
		    Roby::Distributed.warn "  still referencing #{Distributed.peers.keys}"
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
                Roby.class_eval do
                    @plan = nil
                    @engine = nil
                end

		if local
		    local.quit
		end

		timings[:end] = Time.now

	    rescue Exception
		STDERR.puts "failing teardown: #{$!.full_message}"
		raise

	    ensure
		Distributed.logger.level = @old_distributed_logger_level
	    end

	    module RemotePeerSupport
		attr_accessor :testcase

		def enable_communication
		    synchronize do
			local_peer.enable_rx
			# make sure we wake up the communication thread
			finished_discovery.broadcast
		    end
		end
		def disable_communication
		    local_peer.disable_rx
		end
		def flush; local_peer.flush end
		def process_events; engine.process_events end
		def local_peer
		    @local_peer ||= peers.find { true }.last
		end
		def reset_local_peer; @local_peer = nil end
		def send_local_peer(*args); local_peer.send(*args) end
		def wait_one_cycle; engine.wait_one_cycle end
		def console_logger=(value); testcase.console_logger = value end
		def log_level=(value); Roby.logger.level = value end
		def cleanup
		    engine.quit
		    engine.join
		end
                def disable_logging
                    logger = Roby::Distributed.logger
                    @orig_logger_level = logger.level
                    logger.level = Logger::UNKNOWN
                end
                def enable_logging
                    logger = Roby::Distributed.logger
                    logger.level = (@orig_logger_level || Logger::WARN)
                end
	    end

	    # Start a central discovery service, a remote connectionspace and a local
	    # connection space. It yields the remote connection space *in the forked
	    # child* if a block is given.
	    def start_peers
		DRb.stop_service
		remote_process do
		    DRb.start_service DISCOVERY_SERVER, Rinda::TupleSpace.new
		end

		if engine.running?
		    begin
			engine.quit
			engine.join
		    rescue ControlQuitError
		    end
		end

		remote_process do
		    central_tuplespace = DRbObject.new_with_uri(DISCOVERY_SERVER)

		    cs = ConnectionSpace.new :ring_discovery => false, 
			:discovery_tuplespace => central_tuplespace, :name => "remote",
                        :plan => plan

                    getter = Class.new do
                        attr_accessor :cs
                        def get; DRbObject.new(cs) end
                    end.new
                    getter.cs = cs

                    Distributed.state = cs

                    DRb.start_service REMOTE_SERVER, getter

		    cs.extend RemotePeerSupport
		    cs.testcase = self

		    def cs.start_control_thread
			engine.run
		    end

		    yield(cs) if block_given?
		end

		DRb.start_service LOCAL_SERVER
		@central_tuplespace = DRbObject.new_with_uri(DISCOVERY_SERVER)
		@remote  = DRbObject.new_with_uri(REMOTE_SERVER).get
		@local   = ConnectionSpace.new :ring_discovery => false, 
		    :discovery_tuplespace => central_tuplespace, :name => 'local', 
		    :plan => plan
                Distributed.state = local

                remote.start_control_thread
                engine.run
	    end

	    def setup_connection
		assert(remote_neighbour = local.neighbours.find { true })
		Peer.initiate_connection(local, remote_neighbour) do |remote_peer|
                    @remote_peer = peer
                end

		while !remote_peer
		    process_events
		end
		assert(remote.send_local_peer(:connected?))
	    end

	    attr_reader :central_tuplespace, :remote, :remote_peer, :remote_plan, :local

	    # Establishes a peer to peer connection between two ConnectionSpace objects
	    def peer2peer(&remote_init)
		timings[:starting_peers] = Time.now
		start_peers(&remote_init)
		setup_connection
		timings[:started_peers] = Time.now
	    end

	    def process_events
		if engine.running?
		    remote.wait_one_cycle
		    engine.wait_one_cycle
		elsif remote_peer && !remote_peer.disconnected?
		    Roby.synchronize do
			remote.process_events
			engine.process_events
		    end
		else
		    super
		end
	    end

	    def remote_task(match)
		set_permanent = match.delete(:permanent)

		found = nil
		remote_peer.find_tasks.with_arguments(match).each do |task|
		    assert(!found)
		    if set_permanent
			plan.add_permanent(task)
		    end

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
		    DRb.start_service REMOTE_SERVER, server
		end

		DRb.start_service LOCAL_SERVER
		DRbObject.new_with_uri(REMOTE_SERVER)
	    end
	end
    end
end
