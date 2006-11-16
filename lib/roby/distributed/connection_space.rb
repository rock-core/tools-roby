require 'rinda/ring'
require 'rinda/tuplespace'
require 'roby/distributed/drb'
require 'roby/distributed/peer'
require 'utilrb/time/to_hms'
require 'utilrb/kernel/options'

module Roby::Distributed
    extend Logger::Hierarchy
    extend Logger::Forward

    DISCOVERY_RING_PORT = 48932

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
	# The list of broadcasting addresses to search for plan databases
	attr_reader :ring_broadcast
	# If we are doing discovery based on a central tuplespace
	def central_discovery?; !!@discovery_tuplespace end
	# The central tuplespace where neighbours are announced
	attr_reader :discovery_tuplespace
	# Last time a discovery finished
	attr_reader :last_discovery
	# A condition variable which is signalled to start a new discovery
	attr_reader :start_discovery
	# A condition variable which is signalled when discovery finishes
	attr_reader :finished_discovery
	# The plan we are publishing, usually Control.instance.plan
	attr_reader :plan

	# The agent name on the network
	attr_reader :name

	def initialize(options = {})
	    options = validate_options options, 
		:name => "#{Socket.gethostname}-#{Process.pid}", # the name of this host
		:period => nil,				    # the discovery period
		:ring_discovery => true,		    # wether we should do discovery based on Rinda::RingFinger
		:ring_broadcast => '',			    # the broadcast address for discovery
		:discovery_tuplespace => nil,		    # a central tuplespace which lists hosts (including ourselves)
		:plan => nil				    # the plan we publish, uses Control.instance.plan if nil

	    if options[:ring_discovery] && !options[:period]
		raise ArgumentError, "you must provide a discovery period when using ring discovery"
	    end

	    super(0)

	    @name		  = options[:name]
	    @neighbours	  = Array.new
	    @peers		  = Hash.new
	    @connection_listeners = Array.new
	    @connection_listeners << Peer.method(:connection_listener)
	    @plan		  = options[:plan] || Roby::Control.instance.plan

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

	def discovery_port
	    if Roby::Distributed.server
		Roby::Distributed.server.port
	    else DISCOVERY_RING_PORT
	    end
	end

	# Loop which does neighbour_discovery
	def neighbour_discovery
	    new_neighbours = Queue.new

	    # Initialize so that @discovery_start == discovery_start
	    discovery_start = nil
	    finger	    = nil
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

		    if ring_discovery? && (!finger || (finger.port != discovery_port))
			finger = Rinda::RingFinger.new(ring_broadcast, discovery_port)
		    end
		end

		if central_discovery?
		    Roby::Distributed.debug "doing centralized neighbour discovery"
		    discovery_tuplespace.read_all([:host, nil, nil]).
			each do |n| 
			    next if n[0] == self
			    n = Neighbour.new(n[2], n[1]) 
			    Roby::Distributed.debug { "new neighbour: #{n.name} #{n.tuplespace}" }
			    new_neighbours << n
			end
		end

		if discovery_period
		    remaining = (@discovery_start + discovery_period) - Time.now
		    Roby::Distributed.debug { "#{Integer(remaining * 1000)}ms left for discovery" }
		end

		if ring_discovery?
		    Roby::Distributed.debug "doing RingServer neighbour discovery"
		    finger.lookup_ring(remaining) do |ts|
			next if ts == self

			Roby::Distributed.debug { "new neighbour: #{ts.name} #{ts}" }
			new_neighbours << Neighbour.new(ts.name, ts)
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
	attr_accessor :state
	attr_reader :server

	# Publish Distributed.state on the network
	def published?; !!@server end
	def publish(options = {})
	    options[:port] ||= DISCOVERY_RING_PORT
	    @server = RingServer.new(state, options) 
	end
	def unpublish
	    if server 
		server.close
		@server = nil
	    end
	end

	# The list of known neighbours. See ConnectionSpace#neighbours
	def neighbours; state.neighbours end
	# The list of known peers. See ConnectionSpace#peers
	def peers; state.peers end
    end

    class TeamServer
	include DRbUndumped
    end
end

