require 'rinda/ring'
require 'rinda/tuplespace'
require 'utilrb/time/to_hms'
require 'utilrb/kernel/options'

require 'roby/distributed/drb'
require 'roby/distributed/peer'

module Roby
    module Distributed
	extend Logger::Hierarchy
	extend Logger::Forward

	DISCOVERY_RING_PORT = 48932

	# A neighbour is a named remote ConnectionSpace object
	class Neighbour
	    attr_reader :name, :tuplespace
	    attr_accessor :peer
	    def initialize(name, tuplespace)
		@name, @tuplespace = name, tuplespace
	    end

	    def connect; Peer.new(ConnectionSpace.state, peer) end
	    def connecting?; peer && peer.connecting?  end
	    def connected?; peer && peer.connected?  end

	    def ==(other)
		other.kind_of?(Neighbour) &&
		    (tuplespace == other.tuplespace)
	    end
	    def eql?(other); other == self end
	end



	def self.remote_id
	    if state then state.tuplespace 
	    else nil
	    end
	end
	def self.owns?(object); state.owns?(object) end
	def self.peer(id)
	    if id.kind_of?(DRbObject)
		peers[id]
	    elsif id.respond_to?(:to_str)
		peers.each { |_, p| return p if p.remote_name == id.to_str }
		nil
	    elsif id == Roby::Distributed.remote_id
		Roby::Distributed
	    else
		nil
	    end
	end

	def self.subscribed?(object)
	    object.subscribed?
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
	class ConnectionSpace
	    include DRbUndumped
	    include MonitorMixin

	    # Our tuplespace
	    attr_reader :tuplespace

	    # List of discovered neighbours
	    def neighbours; synchronize { @neighbours.dup } end
	    # A queue containing all new neighbours
	    attr_reader :new_neighbours
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
	    # How many errors are allowed before killing a peer to peer connection
	    attr_reader :max_allowed_errors

	    # The agent name on the network
	    attr_reader :name

	    def initialize(options = {})
		super()

		options = validate_options options, 
		    :name => "#{Socket.gethostname}-#{Process.pid}", # the name of this host
		    :period => nil,				    # the discovery period
		    :ring_discovery => true,		    # wether we should do discovery based on Rinda::RingFinger
		    :ring_broadcast => '',			    # the broadcast address for discovery
		    :discovery_tuplespace => nil,		    # a central tuplespace which lists hosts (including ourselves)
		    :plan => nil,				    # the plan we publish, uses Control.instance.plan if nil
		    :max_allowed_errors => 10

		if options[:ring_discovery] && !options[:period]
		    raise ArgumentError, "you must provide a discovery period when using ring discovery"
		end

		@tuplespace = Rinda::TupleSpace.new

		@name                 = options[:name]
		@neighbours           = Array.new
		@peers                = Hash.new
		@plan                 = options[:plan] || Roby::Control.instance.plan
		@max_allowed_errors   = options[:max_allowed_errors]
		@discovery_period     = options[:period]
		@ring_discovery       = options[:ring_discovery]
		@ring_broadcast       = options[:ring_broadcast]
		@discovery_tuplespace = options[:discovery_tuplespace]
		@start_discovery      = new_cond
		@finished_discovery   = new_cond
		@new_neighbours	      = Queue.new

		@connection_listeners = Array.new
		@connection_listeners << Peer.method(:connection_listener)

		yield(self) if block_given?

		if central_discovery?
		    if (@discovery_tuplespace.write([:host, tuplespace, tuplespace.object_id, name]) rescue nil)
			if @discovery_tuplespace.kind_of?(DRbObject)
			    Distributed.info "published ourselves on #{@discovery_tuplespace.__drburi}"
			else
			    Distributed.info "published ourselves on local tuplespace"
			end
		    else
			Distributed.warn "cannot connect to #{@discovery_tuplespace.__drburi}, disabling centralized discovery"
			@discovery_tuplespace = nil
		    end
		end

		if ring_discovery?
		    Distributed.info "doing ring discovery on #{ring_broadcast}"
		end

		# Start the discovery thread and wait for it to be initialized
		synchronize do
		    @discovery_thread = Thread.new(&method(:neighbour_discovery))
		    finished_discovery.wait
		end

		Roby::Control.finalizers << method(:quit)
	    end

	    def discovering?; synchronize { @last_discovery != @discovery_start } end
	    def owns?(object); object.owners.include?(tuplespace) end

	    # An array of procs called at the end of the neighbour discovery,
	    # after #neighbours have been updated
	    attr_reader :connection_listeners

	    def discovery_port
		if Distributed.server
		    Distributed.server.port
		else DISCOVERY_RING_PORT
		end
	    end

	    # Loop which does neighbour_discovery
	    def neighbour_discovery
		discovered = []

		# Initialize so that @discovery_start == discovery_start
		discovery_start = nil
		finger	    = nil
		loop do
		    return if @quit_neighbour_thread

		    Control.synchronize do
			old_neighbours, @neighbours = @neighbours, []
			for new in discovered
			    unless @neighbours.include?(new)
				@neighbours << new
				unless old_neighbours.include?(new)
				    new_neighbours << [self, new]
				end
			    end
			end
		    end

		    connection_listeners.each { |listen| listen.call(self) }
		    synchronize do

			@last_discovery = discovery_start
			finished_discovery.broadcast

			if @discovery_start == @last_discovery
			    #Distributed.debug { "waiting next discovery start" }
			    start_discovery.wait
			end
			return if @quit_neighbour_thread
			discovery_start = @discovery_start

			if ring_discovery? && (!finger || (finger.port != discovery_port))
			    finger = Rinda::RingFinger.new(ring_broadcast, discovery_port)
			end
		    end

		    from = Time.now
		    if central_discovery?
			#Distributed.debug "doing centralized neighbour discovery"
			discovery_tuplespace.read_all([:host, nil, nil, nil]).
			    each do |n| 
				next if n[1] == tuplespace
				n = Neighbour.new(n[3], n[1]) 
				# Distributed.debug { "found neighbour: #{n.name} #{n.tuplespace.inspect}" }
				discovered << n
			    end
		    end

		    if discovery_period
			remaining = (@discovery_start + discovery_period) - Time.now
			#Distributed.debug { "#{Integer(remaining * 1000)}ms left for discovery" }
		    end

		    if ring_discovery?
			#Distributed.debug "doing RingServer neighbour discovery"
			finger.lookup_ring(remaining) do |ts|
			    next if ts == self

			    # Distributed.debug { "found neighbour: #{ts.name} #{ts}" }
			    discovered << Neighbour.new(ts.name, ts)
			end
		    end
		end

	    rescue Exception => e
		Distributed.fatal "neighbour discovery died with\n#{e.full_message}"
	    ensure
		neighbours.clear
		new_neighbours.clear
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

	    def quit
		Distributed.debug "ConnectionSpace #{self} quitting"

		# Remove us from the central tuplespace
		if central_discovery?
		    @discovery_tuplespace.take [:host, tuplespace, nil, nil]
		end

		# Make the neighbour discovery thread quit as well
		synchronize do
		    @quit_neighbour_thread = true
		    start_neighbour_discovery(false)
		end
		@discovery_thread.join
	    end

	    # Disable the keeper thread, we will do cleanup ourselves
	    def start_keeper; end

	    def transaction_prepare_commit(trsc)
		!trsc.valid_transaction?
	    end
	    def transaction_abandon_commit(trsc, reason)
		trsc.abandoned_commit(reason)
	    end
	    def transaction_commit(trsc)
		trsc.commit_transaction(false)
	    end
	    def transaction_discard(trsc)
		trsc.discard_transaction(false)
	    end
	end

	class << self
	    attr_reader :state
	    def state=(new_state)
		if log = logger
		    if new_state
			logger.progname = "Roby (#{new_state.name})"
		    else
			logger.progname = "Roby"
		    end
		end
		@state = new_state
	    end
	    attr_reader :server

	    # Publish Distributed.state on the network
	    def published?; !!@server end
	    def publish(options = {})
		options[:port] ||= DISCOVERY_RING_PORT
		@server = RingServer.new(state, options) 
		Distributed.info "listening for distributed discovery on #{options[:port]}"
	    end
	    def unpublish
		if server 
		    server.close
		    @server = nil
		    Distributed.info "disabled distributed discovery"
		end
	    end

	    # The list of known neighbours. See ConnectionSpace#neighbours
	    def neighbours
		if state then state.neighbours
		else []
		end
	    end

	    def new_neighbours
		if state then state.new_neighbours
		else []
		end
	    end

	    # The list of known peers. See ConnectionSpace#peers
	    def peers; 
		if state then state.peers 
		else []
		end
	    end
	end
	allow_remote_access ConnectionSpace

	@new_neighbours_observers = Array.new
	class << self
	    attr_reader :new_neighbours_observers
	    
	    # Called in the neighbour discovery thread to detect new
	    # neighbours. It fills the new_neighbours queue which is read by
	    # notify_new_neighbours to notify application code of new
	    # neighbours in the control thread
	    def notify_new_neighbours
		return unless Distributed.state
		new_neighbours.get(true).each do |cs, n|
		    new_neighbours_observers.each do |obs|
			obs[cs, n]
		    end
		end
	    end

	    def on_neighbour
		new_neighbours_observers << lambda { |_, n| yield(n) }
	    end
	end
	Roby::Control.event_processing << method(:notify_new_neighbours)
    end
end

