require 'rinda/ring'
require 'rinda/tuplespace'
require 'utilrb/time/to_hms'
require 'utilrb/kernel/options'

require 'roby/distributed/drb'
require 'roby/distributed/peer'

module Roby
    module Distributed
	DISCOVERY_RING_PORT = 48932

	# A neighbour is a named remote ConnectionSpace object
	class Neighbour
	    attr_reader :name, :tuplespace
	    def initialize(name, tuplespace)
		@name, @tuplespace = name, tuplespace
	    end

	    def connect; Peer.new(ConnectionSpace.state, peer) end
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
	def self.peer(id)
	    if id.kind_of?(DRbObject)
		peers[id]
	    elsif id.respond_to?(:to_str)
		peers.each_value { |p| return p if p.remote_name == id.to_str }
		nil
	    elsif id == Roby::Distributed.remote_id
		Roby::Distributed
	    else
		nil
	    end
	end
	def self.transmit(*args)
	    if Thread.current == Roby.control.thread
		raise "in control thread"
	    end

	    Roby::Control.once do
		result = Distributed.state.send(*args)
		yield(result) if block_given?
	    end
	end
	def self.call(*args)
	    Distributed.state.send(*args)
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
	    # The main mutex which is used for synchronization with the discovery
	    # thread
	    attr_reader :mutex
	    def synchronize; mutex.synchronize { yield } end
	    # A condition variable which is signalled to start a new discovery
	    attr_reader :start_discovery
	    # A condition variable which is signalled when discovery finishes
	    attr_reader :finished_discovery
	    # The plan we are publishing, usually Roby.plan
	    attr_reader :plan

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
		    :plan => nil 				    # the plan we publish, uses Roby.plan if nil

		if options[:ring_discovery] && !options[:period]
		    raise ArgumentError, "you must provide a discovery period when using ring discovery"
		end

		@tuplespace = Rinda::TupleSpace.new

		@name                 = options[:name]
		@neighbours           = Array.new
		@peers                = Hash.new
		@plan                 = options[:plan] || Roby.plan
		@discovery_period     = options[:period]
		@ring_discovery       = options[:ring_discovery]
		@ring_broadcast       = options[:ring_broadcast]
		@discovery_tuplespace = options[:discovery_tuplespace]

		@mutex		      = Mutex.new
		@start_discovery      = ConditionVariable.new
		@finished_discovery   = ConditionVariable.new
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

		synchronize do
		    # Start the discovery thread and wait for it to be initialized
		    @discovery_thread = Thread.new(&method(:neighbour_discovery))
		    finished_discovery.wait(mutex)
		end
		start_neighbour_discovery(true)

		Roby::Control.finalizers << method(:quit)
	    end

	    def discovering?
	       	synchronize do 
		    if @last_discovery != @discovery_start
			yield if block_given?
			true
		    end
		end
	    end

	    def owns?(object); object.owners.include?(Roby::Distributed) end

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
			discovered.clear
		    end

		    connection_listeners.each { |listen| listen.call(self) }
		    synchronize do
			@last_discovery = discovery_start
			finished_discovery.broadcast

			if @discovery_start == @last_discovery
			    start_discovery.wait(mutex)
			end
			return if @quit_neighbour_thread
			discovery_start = @discovery_start

			if ring_discovery? && (!finger || (finger.port != discovery_port))
			    finger = Rinda::RingFinger.new(ring_broadcast, discovery_port)
			end
		    end

		    from = Time.now
		    if central_discovery?
			discovery_tuplespace.read_all([:host, nil, nil, nil]).
			    each do |n| 
				next if n[1] == tuplespace
				n = Neighbour.new(n[3], n[1]) 
				discovered << n
			    end
		    end

		    if discovery_period
			remaining = (@discovery_start + discovery_period) - Time.now
		    end

		    if ring_discovery?
			finger.lookup_ring(remaining) do |ts|
			    next if ts == self

			    discovered << Neighbour.new(ts.name, ts)
			end
		    end
		end

	    rescue Interrupt
	    rescue Exception => e
		Distributed.fatal "neighbour discovery died with\n#{e.full_message}"
	    ensure
		Distributed.info "quit neighbour thread"
		neighbours.clear
		new_neighbours.clear

		# Force disconnection in case something got wrong in the normal
		# disconnection process
		Distributed.peers.each_value do |peer|
		    peer.disconnected! rescue nil
		    peer.disconnect rescue nil
		    peer.disconnected rescue nil
		end
	    end

	    # Starts one neighbour discovery loop
	    def start_neighbour_discovery(block = false)
		synchronize do
		    @discovery_start = Time.now
		    start_discovery.signal
		end
		wait_discovery if block
	    end
	    def wait_discovery
		discovering? do
		    finished_discovery.wait(mutex)
		end
	    end

	    def droby_dump(dest)
		@__droby_marshalled__ ||= Peer::DRoby.new(DRbObject.new(tuplespace))
	    end

	    def quit
		Distributed.debug "ConnectionSpace #{self} quitting"

		# Remove us from the central tuplespace
		if central_discovery?
		    begin
			@discovery_tuplespace.take [:host, tuplespace, nil, nil]
		    rescue DRb::DRbConnError, Rinda::RequestExpiredError
		    end
		end

		# Make the neighbour discovery thread quit as well
		@discovery_thread.raise Interrupt, "forcing discovery thread quit"
		@discovery_thread.join

	    ensure
		Roby::Control.finalizers.delete(method(:quit))
		if Distributed.state == self
		    Distributed.state = nil
		end
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
		loop do
		    neighbour = new_neighbours.pop(true) rescue nil
		    break unless neighbour
		    new_neighbours_observers.each do |obs|
			obs[cs, neighbour]
		    end
		end
	    end

	    def on_neighbour
		current = neighbours.dup
		Roby::Control.once { current.each { |n| yield(n) } }
		new_neighbours_observers << lambda { |_, n| yield(n) }
	    end
	end
	Roby::Control.event_processing << method(:notify_new_neighbours)
    end
end

