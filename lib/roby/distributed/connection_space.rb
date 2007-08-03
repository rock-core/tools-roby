require 'rinda/ring'
require 'rinda/tuplespace'
require 'utilrb/time/to_hms'
require 'utilrb/kernel/options'
require 'utilrb/socket/tcp_server'

require 'roby/distributed/drb'
require 'roby/distributed/peer'

module Roby
    module Distributed
	# A neighbour is a named remote ConnectionSpace object
	class Neighbour
	    attr_reader :name, :remote_id
	    def initialize(name, remote_id)
		@name, @remote_id = name, remote_id
	    end

	    def connect; Peer.initiate_connection(ConnectionSpace.state, peer) end
	    def ==(other)
		other.kind_of?(Neighbour) &&
		    (remote_id == other.remote_id)
	    end
	    def to_s; "#<Neighbour:#{name} #{remote_id}>" end
	    def eql?(other); other == self end
	end

	def self.peer(id)
	    if id.kind_of?(Distributed::RemoteID)
		if id == remote_id
		    Distributed
		else
		    peers[id]
		end
	    elsif id.respond_to?(:to_str)
		peers.each_value { |p| return p if p.remote_name == id.to_str }
		nil
	    else
		nil
	    end
	end

	def self.remote_id
	    if state then state.remote_id
	    else @__single_remote_id__ ||= RemoteID.new('local', 0)
	    end
	end

	def self.droby_dump(dest = nil)
	    if state then state.droby_dump(dest)
	    else @__single_marshalled_peer__ ||= Peer::DRoby.new('single', remote_id)
	    end
	end

	def self.transmit(*args)
	    Roby::Control.once do
		result = Distributed.state.send(*args)
		yield(result) if block_given?
	    end
	end

	def self.call(*args)
	    Roby.execute do
		Distributed.state.send(*args)
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

	    # List of discovered neighbours
	    def neighbours; synchronize { @neighbours.dup } end
	    # A queue containing all new neighbours
	    attr_reader :new_neighbours
	    # A remote_id => Peer map
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

	    # The main mutex which is used for synchronization with the discovery
	    # thread
	    attr_reader :mutex
	    def synchronize; mutex.synchronize { yield } end
	    # The plan we are publishing, usually Roby.plan
	    attr_reader :plan

	    # Our name on the network
	    attr_reader :name
	    # The socket on which we listen for incoming connections
	    attr_reader :server_socket

	    def initialize(options = {})
		super()

		options = validate_options options, 
		    :name => "#{Socket.gethostname}-#{Process.pid}", # the name of this host
		    :period => nil,				     # the discovery period
		    :ring_discovery => true,			     # wether we should do discovery based on Rinda::RingFinger
		    :ring_broadcast => '',			     # the broadcast address for discovery
		    :discovery_tuplespace => nil,		     # a central tuplespace which lists hosts (including ourselves)
		    :plan => nil, 				     # the plan we publish, uses Roby.plan if nil
		    :listen_at => 0				     # the port at which we listen for incoming connections

		if options[:ring_discovery] && !options[:period]
		    raise ArgumentError, "you must provide a discovery period when using ring discovery"
		end

		@name                 = options[:name]
		@neighbours           = Array.new
		@peers                = Hash.new
		@plan                 = options[:plan] || Roby.plan
		@discovery_period     = options[:period]
		@ring_discovery       = options[:ring_discovery]
		@ring_broadcast       = options[:ring_broadcast]
		@discovery_tuplespace = options[:discovery_tuplespace]
		@port		      = options[:port]
		@pending_sockets = Queue.new

		@mutex		      = Mutex.new
		@start_discovery      = ConditionVariable.new
		@finished_discovery   = ConditionVariable.new
		@new_neighbours	      = Queue.new

		@connection_listeners = Array.new

		yield(self) if block_given?

		listen(options[:listen_at])
		@remote_id = RemoteID.new(Socket.gethostname, server_socket.port)

		if central_discovery?
		    if (discovery_tuplespace.write([:droby, name, remote_id]) rescue nil)
			if discovery_tuplespace.kind_of?(DRbObject)
			    Distributed.info "published #{name}(#{remote_id}) on #{discovery_tuplespace.__drburi}"
			else
			    Distributed.info "published #{name}(#{remote_id}) on local tuplespace"
			end
		    else
			Distributed.warn "cannot connect to #{discovery_tuplespace.__drburi}, disabling centralized discovery"
			discovery_tuplespace = nil
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

		receive

		Roby::Control.finalizers << method(:quit)
	    end

	    # Sets up a separate thread which listens for connection
	    def listen(port)
		@server_socket = TCPServer.new(nil, port)
		server_socket.listen(10)
		Thread.new do
		    begin
			while new_connection = server_socket.accept
			    Peer.connection_request(self, new_connection)
			end
		    rescue
		    end
		end
	    end

	    attr_reader :remote_id

	    # The set of new sockets to wait for. If one of these is closed,
	    # Distributed.receive will check wether we are supposed to be
	    # connected to the peer. If it's not the case, the socket will be
	    # ignored.
	    attr_reader :pending_sockets
	    
	    # The reception thread
	    def receive
		sockets = Hash.new
		Thread.new do
		    while true
			begin
			    while !pending_sockets.empty?
				socket, peer = pending_sockets.shift
				sockets[socket] = peer
				Roby::Distributed.debug "listening to #{socket} for #{peer}"
			    end

			    begin
				sockets.delete_if { |s, p| s.closed? && p.disconnected? }
				read, _, errors = select(sockets.keys, nil, sockets.keys, 0.1)
			    rescue IOError
			    end
			    
			    if read
				for socket in read
				    if socket.closed? || socket.eof?
					errors << socket
					next
				    end

				    p = sockets[socket]

				    id, size = socket.read(8).unpack("NN")
				    data     = socket.read(size)
				    p.stats.rx += (size + 8)
				    Roby::Distributed.cycles_rx << [p, Marshal.load(data)]
				end
			    end

			    if errors
				for socket in errors
				    p = sockets[socket]

				    if p.connected?
					Roby::Distributed.info "lost connection with #{p}"
				    elsif p.disconnecting?
					Roby::Distributed.info "#{p} disconnected"
					p.disconnected
				    end
				    Roby::Distributed.debug p.connection_state
				end
			    end

			rescue Exception
			    Roby::Distributed.fatal "error in ConnectionSpace#receive: #{$!.full_message}"
			end
		    end
		end
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
		Thread.current.priority = 2

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
			discovery_tuplespace.read_all([:droby, nil, nil]).
			    each do |n| 
				next if n[2] == remote_id
				n = Neighbour.new(n[1], n[2]) 
				discovered << n
			    end
		    end

		    if discovery_period
			remaining = (@discovery_start + discovery_period) - Time.now
		    end

		    if ring_discovery?
			finger.lookup_ring(remaining) do |cs|
			    next if cs == self

			    discovered << Neighbour.new(cs.name, cs.remote_id)
			end
		    end
		end

	    rescue Interrupt
	    rescue Exception => e
		Distributed.fatal "neighbour discovery died with\n#{e.full_message}"
		Distributed.fatal "Peers are: #{Distributed.peers.map { |id, peer| "#{id.inspect} => #{peer}" }.join(", ")}"

	    ensure
		Distributed.info "quit neighbour thread"
		neighbours.clear
		new_neighbours.clear

		# Force disconnection in case something got wrong in the normal
		# disconnection process
		Distributed.peers.values.each do |peer|
		    peer.disconnected unless peer.disconnected?
		end

		synchronize do
		    @discovery_thread = nil
		    finished_discovery.broadcast
		end
	    end

	    # Starts one neighbour discovery loop
	    def start_neighbour_discovery(block = false)
		synchronize do
		    unless discovery_thread && discovery_thread.alive?
			raise "no discovery thread"
		    end

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
	    def wait_next_discovery
		synchronize do
		    unless discovery_thread && discovery_thread.alive?
			raise "no discovery thread"
		    end
		    finished_discovery.wait(mutex)
		end
	    end

	    # Define #droby_dump for Peer-like behaviour
	    def droby_dump(dest = nil); @__droby_marshalled__ ||= Peer::DRoby.new(name, remote_id) end

	    def quit
		Distributed.debug "ConnectionSpace #{self} quitting"

		# Remove us from the central tuplespace
		if central_discovery?
		    begin
			discovery_tuplespace.take [:host, nil, remote_id], 0
		    rescue DRb::DRbConnError, Rinda::RequestExpiredError
		    end
		end

		# Make the neighbour discovery thread quit as well
		thread = synchronize do
		    if thread = @discovery_thread
			thread.raise Interrupt, "forcing discovery thread quit"
		    end
		    thread
		end
		if thread 
		    thread.join
		end

	    ensure
		server_socket.close if server_socket
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
		    cs, neighbour = new_neighbours.pop(true) rescue nil
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

