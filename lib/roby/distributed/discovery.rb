require 'rinda/ring'
require 'rinda/tuplespace'

module Rinda
    class NotifyTemplateEntry
	def pop(nonblock = false)
	    raise RequestExpiredError if @done
	    it = @queue.pop(nonblock) rescue nil
	    @done = true if it && it[0] == 'close'
	    return it
	end
    end
end

module Roby
    module Distributed
	# Reimplements Rinda::RingServer, removing the tuplespace intermediate and
	# the creation of most threads. This is done for performance reasons.
	class RingServer < Rinda::RingServer
	    # Added a :bind option
	    def initialize(ts, options = {})
		options = validate_options options, :bind => '', :port => Rinda::Ring_PORT
		@ts  = ts
		@soc = UDPSocket.new
		@soc.bind options[:bind], options[:port]
		@w_service = write_service
	    end

	    def do_write(msg)
		tuple, timeout = Marshal.load(msg)
		tuple[1].call(@ts) rescue nil
	    rescue
	    end
	end

	# A neighbour is a named remote ConnectionSpace object
	Neighbour = Struct.new :name, :tuplespace

	# Connection discovery based on Rinda::RingServer
	#
	# Each plan database spawns its own RingServer, providing:
	# * the list of other robots it has been involved with and the status of
	# this connection: if it is currently connected, if the two agents are
	# still related, for how long they did not have any connection. This list is
	# of the form
	#	[:name, PeerServer, DrbObject, name]
	#
	# * the list of teams it is part of
	#	[:name, TeamServer, DrbObject, name]
	#
	class ConnectionSpace < Rinda::TupleSpace
	    # List of discovered neighbours
	    def neighbours; synchronize { @neighbours.dup } end
	    # List of peers
	    attr_reader :peers
	    # The period at which we do discovery
	    attr_reader :discovery_period
	    # The discovery thread
	    attr_reader :discovery_thread

	    # If we are doing discovery based on Rinda::RingFinger
	    def ring_discovery?; @ring_discovery end
	    attr_reader :ring_broadcast
	    # If we are doing centralized discovery based on a central
	    # tuplespace
	    def central_discovery?; @discovery_tuplespace end
	    attr_reader :discovery_tuplespace
	    attr_reader :last_discovery
	    attr_reader :start_discovery, :finished_discovery

	    attr_reader :name

	    def initialize(options = {})
		options = validate_options options, 
		    :name => "#{Socket.gethostname}-#{Process.pid}", # the name of this host
		    :period => nil,				    # the discovery period
		    :ring_discovery => true,		    # wether we should do discovery based on Rinda::RingFinger
		    :ring_broadcast => '',			    # the broadcast address for discovery
		    :discovery_tuplespace => nil		    # a central tuplespace which lists hosts (including ourselves)

		if options[:ring_discovery] && !options[:period]
		    raise ArgumentError, "you must provide a discovery period when using ring discovery"
		end

		super(0)

		@name		  = options[:name]
		@neighbours	  = Array.new
		@peers		  = Hash.new
		@connection_listeners = Array.new
		@connection_listeners << Peer.method(:connection_listener)

		@discovery_period     = options[:period]
		@ring_discovery       = options[:ring_discovery]
		@ring_broadcast       = options[:ring_broadcast]
		@discovery_tuplespace = options[:discovery_tuplespace]
		@start_discovery      = new_cond
		@finished_discovery   = new_cond

		if central_discovery?
		    @discovery_tuplespace.write [:host, self, name]
		end

		# Start the discovery thread and wait for it to be initialized
		synchronize do
		    @discovery_thread = Thread.new(&method(:neighbour_discovery))
		    finished_discovery.wait
		end
	    end

	    def discovering?; synchronize { @last_discovery != @discovery_start } end

	    # An array of procs called at the end of the neighbour discovery,
	    # after #neighbours have been updated
	    attr_reader :connection_listeners
	    
	    # Loop which does neighbour_discovery
	    def neighbour_discovery
		new_neighbours = Queue.new
		finger = Rinda::RingFinger.new(ring_broadcast) if ring_discovery?

		# Initialize so that @discovery_start == discovery_start
		discovery_start = nil
		loop do
		    synchronize do 
			@last_discovery = discovery_start

			@neighbours.clear
			while n = (new_neighbours.pop(true) rescue nil)
			    @neighbours << n unless @neighbours.include?(n)
			end

			connection_listeners.each { |listen| listen.call(self) }
			finished_discovery.signal

			if @discovery_start == @last_discovery
			    start_discovery.wait
			end
			discovery_start = @discovery_start
		    end

		    if central_discovery?
			discovery_tuplespace.read_all([:host, nil, nil]).
			    each { |n| new_neighbours << Neighbour.new(n[2], n[1]) unless n[0] == self }
		    end

		    if discovery_period
			remaining = (@discovery_start + discovery_period) - Time.now
		    end

		    if ring_discovery?
			finger.lookup_ring(remaining) do |ts|
			    new_neighbours << Neighbour.new(ts.name, ts) unless ts == self
			end

		    elsif discovery_period
			sleep(remaining)
		    end
		end
	    end

	    # Starts one neighbour discovery loop
	    def start_neighbour_discovery(block = false)
		synchronize do
		    @discovery_start    = Time.now
		    start_discovery.signal
		end
		wait_discovery if block
	    end
	    def wait_discovery
		synchronize do
		    return unless discovering?
		    finished_discovery.wait
		end
	    end

	    # Disable the keeper thread, we will do cleanup ourselves
	    def start_keeper; end
	end

	class << self
	    attr_reader :state
	    attr_reader :server

	    def state=(connection_space)
		@state = connection_space
	    end

	    def publish(options = {}); @server = RingServer.new(state, options) end
	    
	    def neighbours; state.neighbours end
	    def peers; state.peers end
	end
	
	class TeamServer
	    include DRbUndumped
	end
	class PeerServer
	    include DRbUndumped
	    attr_reader :peer
	    def initialize(peer); @peer = peer end
	end

	class Peer
	    # The ConnectionSpace object we act on
	    attr_reader :connection_space
	    # The local server object for this peer
	    attr_reader :local
	    # The neighbour we are connected to
	    attr_reader :neighbour
	    # The last 'keepalive' tuple we wrote on neighbour ConnectionSpace
	    attr_reader :keepalive

	    # Listens for new connections on Distributed.state
	    def self.connection_listener(connection_space)
		connection_space.read_all( { 'kind' => :peer, 'tuplespace' => nil, 'remote' => nil } ).each do |entry|
		    tuplespace = entry['tuplespace']
		    if peer = connection_space.peers[tuplespace]
			# The peer finalized the handshake
			peer.connected = true if peer.connected.nil?
		    elsif neighbour = connection_space.neighbours.find { |n| n.tuplespace == tuplespace }
			# New connection attempt from a known neighbour
			Peer.new(connection_space, neighbour).connected = true
		    end
		end
	    end

	    # Creates a new peer management object for the remote agent
	    # at +tuplespace+
	    def initialize(connection_space, neighbour)
		@connection_space = connection_space
		@neighbour	  = neighbour
		@local		  ||= PeerServer.new(self)
		connection_space.peers[neighbour.tuplespace] = self
		connect
	    end

	    # Writes a connection tuple into the peer tuplespace
	    # We consider that two peers are connected when there
	    # is this kind of tuple in *both* tuplespaces
	    def connect
		raise "Already connected" if connected?
		ping
	    end

	    attr_accessor :connected

	    # Updates our keepalive token on the peer
	    def ping(timeout = nil)
		old, @keepalive = @keepalive, 
		    neighbour.tuplespace.write({ 'kind' => :peer, 'tuplespace' => connection_space, 'remote' => @local }, timeout)

		old.cancel if old
	    end

	    # Disconnects from the peer
	    def disconnect
		connection_space.peers.delete(neighbour.tuplespace)
		@connected = false
		keepalive.cancel if keepalive

		neighbour.tuplespace.take({ 'kind' => :peer, 'tuplespace' => neighbour.tuplespace, 'remote' => nil }, 0)
	    rescue RequestExpiredError
	    end

	    # Returns true if the connection has been established. See also #alive?
	    def connected?; @connected end

	    # Checks if the connection is currently alive
	    def alive?
		return false unless connected?
		return false unless connection_space.neighbours.find { |n| n.tuplespace == neighbour.tuplespace }
		entry = connection_space.read({'kind' => :peer, 'tuplespace' => neighbour.tuplespace, 'remote' => nil}, 0) rescue nil
		return !!entry
	    end
	end
    end
end

