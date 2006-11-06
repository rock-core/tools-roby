require 'rinda/ring'
require 'rinda/tuplespace'

module Roby::Distributed
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

    def self.lookup_ring(timeout, broadcast_list, port, &block)
      msg = Marshal.dump([[:lookup_ring, DRbObject.new(block)], Time.now + timeout])
      broadcast_list.each do |it|
	soc = UDPSocket.open
	begin
	  soc.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)
	  soc.send(msg, 0, it, port)
	rescue
	ensure
	  soc.close
	end
      end
      sleep(timeout)
    end

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
	attr_reader :finished_discovery

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

	    @name = options[:name]
	    @neighbours = []
	    @discovery_period     = options[:period]
	    @ring_discovery       = options[:ring_discovery]
	    @ring_broadcast       = options[:ring_broadcast]
	    @discovery_tuplespace = options[:discovery_tuplespace]
	    @finished_discovery   = new_cond

	    if central_discovery?
		@discovery_tuplespace.write [:host, self, name]
	    end
	    @discovery_thread = Thread.new(&method(:neighbour_discovery))
	end
	
	# Loop which does neighbour_discovery
	def neighbour_discovery
	    new_neighbours = Queue.new
	    finger = Rinda::RingFinger.new(ring_broadcast) if ring_discovery?

	    loop do
		Thread.stop

		if central_discovery?
		    discovery_tuplespace.read_all([:host, nil, nil]).
			each { |n| new_neighbours << n[1, 2] unless n[0] == self }
		end

		if discovery_period
		    remaining = (@discovery_start + discovery_period) - Time.now
		end

		if ring_discovery?
		    finger.lookup_ring(remaining) do |ts|
			new_neighbours << [ts, ts.name] unless ts == self
		    end

		elsif discovery_period
		    sleep(remaining)
		end

		synchronize do 
		    @neighbours.clear
		    while n = (new_neighbours.pop(true) rescue nil)
			@neighbours << n unless @neighbours.include?(n)
		    end
		    finished_discovery.signal
		end
		new_neighbours.clear
	    end
	end

	# Starts one neighbour discovery loop
	def start_neighbour_discovery
	    @discovery_start = Time.now
	    STDERR.puts "starting discovery"
	    @discovery_thread.run 
	end
	def wait_discovery
	    synchronize(&finished_discovery.method(:wait))
	end

	# Disable the keeper thread, we will do cleanup ourselves
	def start_keeper; end
    end

    class << self
	attr_accessor :state
	attr_reader   :server
	def publish(options = {}); @server = RingServer.new(state, options) end
	
	# The list of plan databases discovered by Rinda::RingFinger
	def neighbours; state.neighbours end

	# A peer is a plan database with which we have explicitely been connected
	attribute(:peers) { Array.new }
    end

    
    class TeamServer
	include DRbUndumped
    end
    class PeerServer
	include DRbUndumped
    end

    class Peer
	# The local server object for this peer
	attr_reader :local
	# The last 'keepalive' tuple we wrote on the remote tuplespace
	attr_reader :keepalive
	# The remote tuplespace
	attr_reader :tuplespace

	# The remote object
	def remote
	    entry = Distributed.status.read({'kind' => :peer, 'tuplespace' => tuplespace, 'remote' => nil}, nil)
	    if entry.expired?
		@alive = false

	    end
	end

	# Creates a new peer management object for the remote agent
	# at +tuplespace+
	def initialize(tuplespace)
	    @tuplespace = tuplespace
	    @local ||= PeerServer.new(self)
	    connect
	end

	# Writes a connection tuple into the peer tuplespace
	# We consider that two peers are connected when there
	# is this kind of tuple in *both* tuplespaces
	def connect
	    raise "Already connected" if connected?
	    ping

	    @connected = true if alive?
	end

	# Updates our keepalive token on the peer
	def ping(timeout = nil)
	    old, @keepalive = @keepalive, tuplespace.write({ 'kind' => :peer, 'tuplespace' => Distributed.status, 'remote' => @local }, timeout)
	    old.cancel if old
	end

	# Disconnects from the peer
	def disconnect
	    @connected = false
	    keepalive.cancel if keepalive

	    tuplespace.take({ 'kind' => :peer, 'tuplespace' => tuplespace, 'remote' => nil }, 0)
	rescue RequestExpiredError
	end

	# Returns true if the connection has been established. See also #alive?
	def connected?; @connected end

	# Checks if the connection is currently alive
	def alive?
	    return false unless connected?
	    return false unless neighbours.include?(remote)
	    return false unless entry = Distributed.status.read('kind' => :peer, 'tuplespace' => tuplespace)
	    return !entry.expired?
	end
    end
end

