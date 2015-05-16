require 'rinda/ring'
require 'rinda/tuplespace'
require 'utilrb/time/to_hms'
require 'utilrb/kernel/options'
require 'utilrb/socket/tcp_server'

module Roby
    module Distributed
        # Returns the Peer object for the given ID. +id+ can be either the peer
        # RemoteID or its name.
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

        # Replaying logged data is a bit tricky, as the local ID manager will
        # think that we are unmarshalling stuff that we marshalled ...
        #
        # The proper solution is a big refactoring of the object management.
        # Unfortunately, it is not that high on the TODO list. For now, create
        # unique remote_id and droby_dump values to make the local process look
        # different from a normal Roby process
        def self.setup_log_replay(object_manager)
            @__single_remote_id__ = RemoteID.new('log_replay', 1)
            @__single_marshalled_peer__ = Peer::DRoby.new('single', remote_id)
            peers[RemoteID.new('local', 0)] = object_manager
        end

        # Returns a RemoteID object suitable to represent this plan manager on
        # the network.
        #
        # This makes Roby::Distributed behave like a Peer object
	def self.remote_id
	    if state then state.remote_id
	    else @__single_remote_id__ ||= RemoteID.new('local', 0)
	    end
	end

        # Returns a Peer::DRoby object which can be used in the dRoby
        # connection to represent this plan manager.
        #
        # This makes Roby::Distributed behave like a Peer object
	def self.droby_dump(dest = nil)
	    if state then state.droby_dump(dest)
	    else @__single_marshalled_peer__ ||= Peer::DRoby.new('single', remote_id)
	    end
	end

        # Execute the given message without blocking. If a block is given,
        # yield the result to that block.
        #
        # This makes Roby::Distributed behave like a Peer object
	def self.transmit(*args)
	    Roby.once do
		result = Distributed.state.send(*args)
		yield(result) if block_given?
	    end
	end

        # Execute the given message and wait for its result to be available.
        #
        # This makes Roby::Distributed behave like a Peer object
	def self.call(*args)
	    Roby.execute do
		Distributed.state.send(*args)
	    end
	end

        # True if this plan manager is subscribed to +object+ 
        #
        # This makes Roby::Distributed behave like a Peer object
	def self.subscribed?(object)
	    object.subscribed?
	end

        # This class manages the connections between this plan manager and the
        # remote plan managers
        #
        # * there is only one reception thread, at which all peers send data
	class ConnectionSpace
	    include DRbUndumped

	    # List of discovered neighbours
	    def neighbours; synchronize { @neighbours.dup } end
	    # A queue containing all new neighbours
	    attr_reader :new_neighbours
	    # A remote_id => Peer map of the connected peers
	    attr_reader :peers
	    # A remote_id => thread of the connection threads
	    #
	    # See Peer.connection_request and Peer.initiate_connection
	    attr_reader :pending_connections
	    # A remote_id => thread of the connection threads
	    #
	    # See Peer.connection_request, Peer.initiate_connection and Peer#reconnect
	    attr_reader :aborted_connections
	    # The set of peers for which we have lost the link
	    attr_reader :pending_reconnections
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
            # The execution engine tied to +plan+, or nil if there is none
            def engine; plan.engine end

	    # Our name on the network
	    attr_reader :name
	    # The socket on which we listen for incoming connections
	    attr_reader :server_socket

            # Create a new ConnectionSpace objects. The following options can be provided:
            #
            # name:: the name of this plan manager. Defaults to <hostname>-<PID>
            # period:: the discovery period [default: nil]
            # ring_discovery:: whether or not ring discovery should be attempted [default: true]
            # ring_broadcast:: the broadcast address for ring discovery
            # discovery_tuplespace:: the DRbObject referencing the remote tuplespace which holds references to plan managers [default: nil]
            # plan:: the plan this ConnectionSpace acts on. [default: Roby.plan]
            # listen_at:: the port at which we should listen for incoming connections [default: 0]
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
		@pending_connections = Hash.new
		@aborted_connections = Hash.new
		@pending_reconnections = Array.new
		@quit_neighbour_thread = false

		@mutex		      = Mutex.new
		@start_discovery      = ConditionVariable.new
		@finished_discovery   = ConditionVariable.new
		@new_neighbours	      = Queue.new
                @new_neighbours_observers = Array.new

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
                    until last_discovery
                        finished_discovery.wait(mutex)
                    end
		end
		start_neighbour_discovery(true)

                @discovery_start_handler = engine.add_propagation_handler do |plan|
                    start_neighbour_discovery
                    notify_new_neighbours
                end
		engine.finalizers << method(:quit)
                engine.at_cycle_end do
                    peers.each_value do |peer|
                        if peer.connected?
                            peer.transmit(:state_update, Roby::State) 
                        end
                    end
                end

                # Finally, start the reception thread
                receive
	    end

	    # Sets up a separate thread which listens for connection
	    def listen(port)
		@server_socket = TCPServer.new(nil, port)
		server_socket.listen(10)
		Thread.new do
		    begin
			while new_connection = server_socket.accept
			    begin
				Peer.connection_request(self, new_connection)
			    rescue Exception => e
				Roby::Distributed.fatal "failed to handle connection request on #{new_connection}"
				Roby::Distributed.fatal e.full_message
				new_connection.close
			    end
			end
		    rescue Exception
		    end
		end
	    end

            # The RemoteID object which allows to reference this ConnectionSpace on the network
	    attr_reader :remote_id

	    # The set of new sockets to wait for. If one of these is closed,
	    # Distributed.receive will check wether we are supposed to be
	    # connected to the peer. If it's not the case, the socket will be
	    # ignored.
	    attr_reader :pending_sockets
	    
	    # Starts the reception thread
	    def receive # :nodoc:
		sockets = Hash.new
		Thread.new do
		    while true
			begin
			    while !pending_sockets.empty?
				socket, peer = pending_sockets.shift
				sockets[socket] = peer
                                begin
                                    Roby::Distributed.info "listening to #{socket.peer_info} for #{peer}"
                                rescue IOError
                                end
			    end

			    begin
				sockets.delete_if { |s, p| s.closed? && p.disconnected? }
				read, _, errors = select(sockets.keys, nil, nil, 0.1)
			    rescue IOError
			    end
			    next if !read
			    
			    closed_sockets = []
			    for socket in read
				if socket.closed?
				    closed_sockets << socket
				    next
				end

                                begin
                                    header = socket.read(8)
                                    unless header && header.size == 8
                                        closed_sockets << socket
                                        next
                                    end

                                    id, size = header.unpack("NN")
                                    data     = socket.read(size)

                                    p = sockets[socket]
                                    p.stats.rx += (size + 8)
                                    Roby::Distributed.cycles_rx << [p, Marshal.load(data)]
                                rescue Errno::ECONNRESET, IOError
                                    closed_sockets << socket
                                end
			    end

			    for socket in closed_sockets
				p = sockets[socket]
				if p.connected?
				    Roby::Distributed.info "lost connection with #{p}"
				    p.reconnect
				    sockets.delete socket
				elsif p.disconnecting?
				    Roby::Distributed.info "#{p} disconnected"
				    p.disconnected
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
                    @last_discovery != @discovery_start
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
		@discovery_start = nil
		discovery_start = nil
		finger	    = nil
		loop do
		    return if @quit_neighbour_thread

		    Roby.synchronize do
			old_neighbours, @neighbours = @neighbours, []
			for new in discovered
			    unless new.remote_id == remote_id || @neighbours.include?(new)
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

			while @discovery_start == @last_discovery
			    start_discovery.wait(mutex)
			end
			return if @quit_neighbour_thread
			discovery_start = @discovery_start
		    end

		    from = Time.now
                    if ring_discovery? && (!finger || (finger.port != discovery_port))
                        finger = Rinda::RingFinger.new(ring_broadcast, discovery_port)
                    end
		    if central_discovery?
			discovery_tuplespace.read_all([:droby, nil, nil]).
			    each do |n| 
				next if n[2] == remote_id
				n = Neighbour.new(n[1], n[2]) 
				discovered << n
			    end
		    end

		    if ring_discovery?
                        if discovery_period
                            remaining = (@discovery_start + discovery_period) - Time.now
                        end

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
		    peer.disconnected! unless peer.disconnected?
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
		    start_discovery.broadcast
		end
		wait_discovery if block
	    end

	    def wait_discovery
                synchronize do 
                    while last_discovery != discovery_start
                        finished_discovery.wait(mutex)
                    end
		end
            end

	    def wait_next_discovery
		synchronize do
		    unless discovery_thread && discovery_thread.alive?
			raise "no discovery thread"
		    end
                    current_discovery = @last_discovery
                    while @last_discovery == current_discovery
                        finished_discovery.wait(mutex)
                    end
		end
	    end

	    # Define #droby_dump for Peer-like behaviour
	    def droby_dump(dest = nil); @__droby_marshalled__ ||= Peer::DRoby.new(name, remote_id) end

            # Make the ConnectionSpace quit
	    def quit
		Distributed.debug "ConnectionSpace #{self} quitting"
                if @discovery_start_handler
                    engine.remove_propagation_handler(@discovery_start_handler)
                end

		# Remove us from the central tuplespace
		if central_discovery?
		    begin
			discovery_tuplespace.take [:droby, nil, remote_id], 0
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
		if server_socket
		    begin
			server_socket.close 
		    rescue IOError
		    end
		end

		plan.engine.finalizers.delete(method(:quit))
		if Distributed.state == self
		    Distributed.state = nil
		end
	    end

	    # Disable the keeper thread, we will do cleanup ourselves
	    def start_keeper; end

            # This makes ConnectionSpace act as a PeerServer object locally
	    def transaction_prepare_commit(trsc) # :nodoc:
		!trsc.valid_transaction?
	    end
            # This makes ConnectionSpace act as a PeerServer object locally
	    def transaction_abandon_commit(trsc, reason) # :nodoc:
		trsc.abandoned_commit(reason)
	    end
            # This makes ConnectionSpace act as a PeerServer object locally
	    def transaction_commit(trsc) # :nodoc:
		trsc.commit_transaction(false)
	    end
            # This makes ConnectionSpace act as a PeerServer object locally
	    def transaction_discard(trsc) # :nodoc:
		trsc.discard_transaction(false)
	    end

            def on_neighbour
		current = neighbours.dup
		engine.once { current.each { |n| yield(n) } }
		new_neighbours_observers << lambda { |_, n| yield(n) }
	    end

            # The set of proc objects which should be notified when new
            # neighbours are detected.
	    attr_reader :new_neighbours_observers
	    
            # Called in the neighbour discovery thread to detect new
            # neighbours. It fills the new_neighbours queue which is read by
            # notify_new_neighbours to notify application code of new
            # neighbours in the control thread
	    def notify_new_neighbours
		while !new_neighbours.empty?
		    cs, neighbour = new_neighbours.pop(true)
		    new_neighbours_observers.each do |obs|
			obs[cs, neighbour]
		    end
		end
	    end

	end

	class << self
            # The RingServer object through which we publish this plan manager
            # on the network
	    attr_reader :server

            # True if we are published on the network.
            #
            # See #server, #publish and #unpublish
	    def published?; !!@server end
            
            # Enable ring discovery on our part. A RingServer object is set up
            # to listen to connections on the port given as a :port option (or
            # DISCOVERY_RING_PORT if none is specified).
            #
            # Note that all plan managers must use the same discovery port.
	    def publish(options = {})
		options[:port] ||= DISCOVERY_RING_PORT
		@server = RingServer.new(state, options) 
		Distributed.info "listening for distributed discovery on #{options[:port]}"
	    end

            # Disable the ring discovery on our part.
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

            # The list of neighbours that have been found since the last
            # execution cycle
	    def new_neighbours
		if state then state.new_neighbours
		else []
		end
	    end
            
            # Defines a block which should be called when a new neighbour is
            # detected
            #
            # See ConnectionSpace#on_neighbour
            def on_neighbour(&block); Roby::Distributed.state.on_neighbour(&block) end
	end
    end
end

