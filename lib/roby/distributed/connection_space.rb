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
	    attr_reader :neighbours
	    # A queue containing all new neighbours
	    attr_reader :new_neighbours
	    # A remote_id => Peer map of the connected peers
	    attr_reader :peers

            # The discovery management object
            #
            # @return [Discovery]
            attr_reader :discovery

	    # The plan we are publishing, usually Roby.plan
	    attr_reader :plan
            # The execution engine tied to +plan+, or nil if there is none
            def execution_engine; plan.execution_engine end
            # The state object
            attr_reader :state

	    # Our name on the network
	    attr_reader :name
	    # The socket on which we listen for incoming connections
	    attr_reader :server_socket

            # Queue of just-received cycles to process from our peers. This is
            # only a communication channel between the com thread and the event
            # thread
            attr_reader :cycles_rx
            # List of [peer, data] cycles remaining to process
            attr_reader :pending_cycles
            # The set of peers whose link just closed
            attr_reader :closed_links

	    # An array of procs called at the end of the neighbour discovery,
	    # after #neighbours have been updated
	    attr_reader :connection_listeners

	    # Define #droby_dump for Peer-like behaviour
	    def droby_dump(dest = nil); @__droby_marshalled__ ||= Peer::DRoby.new(name, remote_id) end


            # Create a new ConnectionSpace objects
	    def initialize(name: "#{Socket.gethostname}-#{Process.pid}", plan: Roby.plan, listen_at: 0, state: Roby::State)
		super()

		@name                 = name
		@neighbours           = Array.new
		@peers                = Hash.new
		@plan                 = plan
                @state                = state
                plan.connection_space = self

                @new_neighbours_observers = Array.new
		@connection_listeners = Array.new

                @cycles_rx             = Queue.new
                @pending_cycles        = Array.new
                @closed_links          = Queue.new

                if block_given?
                    raise ArgumentError, "passing a block to ConnectionSpace#initialize has been discontinued"
                end

		listen(listen_at)
		@remote_id = RemoteID.new(Socket.ip_address_list.first.getnameinfo[0], server_socket.port)

                @discovery = Discovery.new
                @at_cycle_begin_handler = execution_engine.at_cycle_begin do
                    discovery.start
                    process_pending
                end
                @at_cycle_end_handler = execution_engine.at_cycle_end do
                    peers.each_value do |peer|
                        if peer.connected?
                            peer.transmit(:state_update, Roby::State) 
                        end
                    end
                end
		execution_engine.finalizers << method(:quit)

                # Finally, start the reception thread
                receive
	    end

            def each_peer(&block)
                peers.each_value(&block)
            end

	    # Sets up a separate thread which listens for connection
	    def listen(port)
		@server_socket = TCPServer.new(nil, port)
                server_socket.close_on_exec = true
		server_socket.listen(10)

                @listen_trigger = IO.pipe
		@listen_thread = Thread.new do
                    begin
                        while true
                            pending = IO.select([server_socket, @listen_trigger[0]], nil, nil)
                            if pending && (new_connection = server_socket.accept)
                                begin
                                    handle_connection_request(new_connection)
                                rescue Exception => e
                                    Distributed.fatal "#{new_connection}: failed to handle connection request"
                                    Distributed.fatal e.full_message
                                    new_connection.close
                                end
                            end
                        end
                    rescue IOError
                    ensure
                        @listen_trigger.each(&:close)
                        @server_socket, @listen_trigger = nil
                    end
		end
	    end

            def close
                server_socket.close
                @listen_trigger[1].write "Q"
                @receive_trigger[1].write "Q"
                @listen_thread.join
                @listen_thread = nil
                @receive_thread.join
                @receive_thread = nil
            end

            class RemoteNameMismatch < RuntimeError; end

            def handle_connection_request(socket)
		socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

		# read connection info from +socket+
		info_size = socket.read(4).unpack("N").first
		m, remote_token, remote_name, remote_id, remote_state = 
		    Marshal.load(socket.read(info_size))

		Distributed.debug { "#{socket}: connection request local:#{socket.local_address.ip_unpack} remote:#{socket.remote_address.ip_unpack}: #{m} #{remote_name} #{remote_id}" }

                once do
                    if !(peer = peers[remote_id])
                        Distributed.debug { "#{socket}: creating new peer for #{m.inspect}" }
                        peer = Peer.new(self, remote_name, remote_id)
                        register_peer(peer)
                    end

                    reply, transferred_socket_ownership =
                        peer.handle_connection_request(socket, m, remote_name, remote_token, remote_state)
		    reply = Marshal.dump(Distributed.format(reply))
		    socket.write [reply.size].pack("N")
		    socket.write reply
                    if !transferred_socket_ownership
                        socket.close
                    end
                end
            end

            def once(&block)
                execution_engine.once(&block)
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
                @pending_sockets = Queue.new
                @receive_trigger = IO.pipe
		@receive_thread = Thread.new do
                    sockets = Hash.new
		    while true
			begin
                            sockets.delete_if do |s, p|
                                if s.closed?
                                    sockets.delete(s)
                                    closed_links << p
                                    true
                                end
                            end

			    while !pending_sockets.empty?
				peer, socket = pending_sockets.shift
				sockets[socket] = peer
                                Roby::Distributed.info "listening to #{socket.peer_info} for #{peer}"
			    end

			    begin
				read, _ = IO.select([@receive_trigger[0], *sockets.keys])
			    rescue IOError
                                next
			    end

                            if read.delete(@receive_trigger[0])
                                cmd = @receive_trigger[0].read(1)
                                if cmd == "Q"
                                    @receive_trigger.each(&:close)
                                    break
                                end
                            end
			    
                            Roby::Distributed.info "got data on #{read.size} peers"

			    for socket in read
                                begin
                                    header = socket.read(8)
                                    next if !header || header.size < 8

                                    id, size = header.unpack("NN")
                                    data     = socket.read(size)
                                    next if !data || data.size < size

                                    p = sockets[socket]
                                    p.stats.rx += (size + 8)
                                    cycles_rx << [p, Marshal.load(data)]
                                rescue Errno::ECONNRESET, IOError
                                end
			    end

			rescue Exception
			    Roby::Distributed.fatal "error in ConnectionSpace#receive: #{$!.full_message}"
			end
		    end
		end
	    end

	    def owns?(object); object.owners.include?(Roby::Distributed) end

            def register_peer(peer)
                peers[peer.remote_id] = peer

                task = peer.task
                plan.add_permanent(task)
                task.start!
            end

            def register_link(peer, socket)
                pending_sockets << [peer, socket]
                @receive_trigger[1].write "N"
            end

            class PeerTaskNotFinished < RuntimeError; end
            def deregister_peer(peer)
                peers.delete(peer.remote_id)
            end

            # Make the ConnectionSpace quit
	    def quit
		Distributed.debug "ConnectionSpace #{self} quitting"
                execution_engine.remove_propagation_handler(@at_cycle_begin_handler)
                execution_engine.remove_propagation_handler(@at_cycle_end_handler)
                execution_engine.finalizers.delete(method(:quit))

                (ring_discovery_publishers.values + ring_discovery_listeners.values).
                    each do |d|
                        if d.listening?
                            d.stop_listening
                        end
                        if d.registered?
                            d.deregister
                        end
                    end

	    ensure
		if server_socket
		    begin
			server_socket.close 
		    rescue IOError
		    end
		end

		execution_engine.finalizers.delete(method(:quit))
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
		execution_engine.once { current.each { |n| yield(n) } }
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

            # This method will call {PeerServer#trigger} on all peers, for the
            # objects in +objects+ which are eligible for triggering.
            #
            # The same task cannot match the same trigger twice. To allow that,
            # call {#clean_triggered}
            def trigger(*objects)
                objects.delete_if do |o| 
                    o.plan != plan ||
                        !o.distribute? ||
                        !o.self_owned?
                end
                return if objects.empty?

                # If +object+ is a trigger, send the :triggered event but do *not*
                # act as if +object+ was subscribed
                peers.each_value do |peer|
                    peer.local_server.trigger(*objects)
                end
            end

            # Remove +objects+ from the sets of already-triggered objects. So, next
            # time +object+ will be tested for triggers, it will re-match the
            # triggers it has already matched.
            def clean_triggered(object)
                peers.each_value do |peer|
                    peer.local_server.triggers.each_value do |_, triggered|
                        triggered.delete object
                    end
                end
            end

            def add_owner(object, peer)
                object.add_owner(peer, false)
            end
            def remove_owner(object, peer)
                object.remove_owner(peer, false)
            end
            def prepare_remove_owner(object, peer)
                object.prepare_remove_owner(peer)
            rescue Exception => e
                e
            end

            # Yields the peers which are interested in at least one of the
            # objects in +objects+.
            def each_updated_peer(*objects)
                for obj in objects
                    return if !obj.distribute?
                end

                for _, peer in peers
                    next unless peer.connected?
                    for obj in objects
                        if obj.update_on?(peer)
                            yield(peer)
                            break
                        end
                    end
                end
            end

            # Extract data received so far from our peers and replays it if
            # possible. Data can be ignored if RX is disabled with this peer
            # (through Peer#disable_rx), or delayed if there is event propagation
            # involved. In that last case, the events will be fired at the
            # beginning of the next execution cycle and the remaining messages at
            # the end of that same cycle.
            def process_pending
                delayed_cycles = []
                while !(pending_cycles.empty? && cycles_rx.empty?)
                    peer, calls = if pending_cycles.empty?
                                      cycles_rx.pop
                                  else pending_cycles.shift
                                  end

                    if peer.disabled_rx?
                        Distributed.debug { "#{peer}: delaying #{calls.size} calls, RX is disabled" }
                        delayed_cycles.push [peer, calls]
                    else
                        Distributed.debug { "#{peer}: processing #{calls.size} calls" }
                        if remaining = process_cycle(peer, calls)
                            delayed_cycles.push [peer, remaining]
                        end
                    end
                end

                while !closed_links.empty?
                    p = closed_links.pop
                    if p.connected?
                        Roby::Distributed.info "lost connection with #{p}"
                        p.reconnect
                    elsif p.disconnecting?
                        Roby::Distributed.info "#{p} disconnected"
                        p.disconnected
                    end
                end

            ensure
                @pending_cycles = delayed_cycles
            end

            # @api private
            #
            # Process once cycle worth of data from the given peer.
            def process_cycle(peer, calls)
                from = Time.now
                calls_size = calls.size

                peer_server = peer.local_server
                peer_server.processing = true

                if peer.disconnected?
                    Distributed.debug "#{peer}: peer disconnected, ignoring #{calls_size} calls"
                    return
                end

                while call_spec = calls.shift
                    return unless call_spec

                    is_callback, method, args, critical, message_id = *call_spec
                    Distributed.debug do 
                        args_s = args.map { |obj| obj ? obj.to_s : 'nil' }
                        "#{peer}: processing #{is_callback ? 'callback' : 'method'} [#{message_id}]#{method}(#{args_s.join(", ")})"
                    end

                    result = catch(:ignore_this_call) do
                        peer_server.queued_completion = false
                        peer_server.current_message_id = message_id
                        peer_server.processing_callback = !!is_callback

                        result = begin
                                     peer_server.send(method, *args)
                                 rescue Exception => e
                                     if critical
                                         peer.fatal_error e, method, args
                                     else
                                         peer_server.completed!(e, true)
                                     end
                                 end

                        if peer.disconnected?
                            return
                        end
                        result
                    end

                    if method != :completed && method != :completion_group && peer.connected?
                        if peer_server.queued_completion?
                            Distributed.debug "#{peer}: done and already queued the completion message"
                        else
                            Distributed.debug { "#{peer}: done, returns #{result || 'nil'}" }
                            peer.queue_call false, :completed, [result, false, message_id]
                        end
                    end

                    if peer.disabled_rx?
                        return calls
                    end
                end

                Distributed.debug "successfully served #{calls_size} calls in #{Time.now - from} seconds"
                nil

            rescue Exception => e
                Distributed.info "error in dRoby processing: #{e.full_message}"
                peer.disconnect if !peer.disconnected?

            ensure
                peer_server.processing = false
            end
	end
    end
end

