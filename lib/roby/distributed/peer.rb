require 'set'
require 'utilrb/array/to_s'
require 'utilrb/socket/tcp_socket'

module Roby
    module Distributed

    # A Peer object is the client part of a connection with a remote plan
    # manager. The server part, i.e. the object which actually receives
    # requests from the remote plan manager, is the PeerServer object
    # accessible through the Peer#local_server attribute.
    #
    # == Connection procedure
    #
    # Connections are initiated When the user calls Peer.initiate_connection.
    # The following protocol is then followed:
    # [local] 
    #   if the neighbour is already connected to us, we do nothing and yield
    #   the already existing peer. End.
    # [local]
    #   check if we are already connecting to the peer. If it is the case,
    #   wait for the end of the connection thread.
    # [local] 
    #   otherwise, open a new socket and send the connect() message in it
    #   The connection thread is registered in ConnectionSpace.pending_connections
    # [remote] 
    #   check if we are already connecting to the peer (check ConnectionSpace.pending_connections)
    #   * if it is the case, the lowest token wins
    #   * if 'remote' wins, return :already_connecting
    #   * if 'local' wins, return :connected with the relevant information
    #
    # == Communication
    #
    # Communication is done in two threads. The sending thread gets the calls
    # from Peer#send_queue, formats them and sends them to the PeerServer#demux
    # for processing. The reception thread is managed by dRb and its entry
    # point is always #demux.
    #
    # Very often we need to have processing on both sides to finish an
    # operation. For instance, the creation of two siblings need to register
    # the siblings on both sides. To manage that, it is possible for PeerServer
    # methods which are serving a remote request to queue callbacks.  These
    # callbacks will be processed by Peer#send_thread before the rest of the
    # queue might be processed
    class Peer < RemoteObjectManager
	include DRbUndumped

	# The local ConnectionSpace object we act on
	attr_reader :connection_space
	# The local PeerServer object for this peer
	attr_reader :local_server
	# The connection socket with our peer
	attr_reader :socket

	ComStats = Struct.new :rx, :tx
	# A ComStats object which holds the communication statistics for this peer
	# stats.tx is the count of bytes sent to the peer while stats.rx is the
	# count of bytes received
	attr_reader :stats

	def to_s # :nodoc:
            "#<Peer:#{Object.address_from_id(object_id).to_s(16)} #{remote_name}>"
        end

	# The object which identifies this peer on the network
	attr_reader :remote_id
	# The name of the remote peer
	attr_reader :remote_name
	# The [host, port] pair at the peer end
        def peer_info; socket.peer_info if socket end

	# The name of the local ConnectionSpace object we are acting on
	def local_name; connection_space.name end

	# The ID => block hash of all triggers we have defined on the remote plan
	attr_reader :triggers
	# The remote state
	attr_accessor :state

        # The plan associated to our connection space
        def plan; connection_space.plan end
        # The execution engine associated to #plan
        def execution_engine; connection_space.plan.execution_engine end

        # Synchronization primitives for {#wait_link_alive}
        attr_reader :wait_link_alive_sync, :wait_link_alive_cond

	# Creates a Peer object for the peer connected at +socket+. This peer
	# is to be managed by +connection_space+ If a block is given, it is
	# called in the control thread when the connection is finalized
	def initialize(connection_space, remote_name, remote_id)
	    # Initialize the remote name with the socket parameters. It will be set to 
	    # the real name during the connection process
	    @remote_name = remote_name
	    @remote_id   = remote_id

            @wait_link_alive_sync = Mutex.new
            @wait_link_alive_cond = ConditionVariable.new

	    @connection_space = connection_space
	    @local_server = PeerServer.new(self)
	    @mutex	  = Mutex.new
	    @triggers     = Hash.new
	    @stats        = ComStats.new 0, 0
	    @dead	  = false
	    @disabled_rx  = 0
	    @disabled_tx  = 0

	    @connection_state = :disconnected
	    @send_queue       = Queue.new
	    @completion_queue = Queue.new
	    @current_cycle    = Array.new
            @task            = ConnectionTask.new(peer: self)

            super(plan)
	end

        def pretty_print(pp)
            pp.text "Peer:#{remote_name}@#{remote_id} #{connection_state}"
        end

        def connecting?
            connection_state == :connecting
        end

	# The peer name
	attr_reader :name
	# The ConnectionTask object for this peer
	attr_reader :task

	# Creates a query object on the remote plan. 
        #
        # For thread-safe operation, always use #each on the resulting query:
        # during the enumeration, the local plan GC will not remove those
        # tasks.
	def find_tasks
	    Roby::Queries::Query.new(self)
	end

        def removed_sibling(remote_object)
            super
            subscriptions.delete(remote_object)
        end

        # Returns a set of remote tasks for +query+ applied on the remote plan
        # This is not to be accessed directly. It is part of the Query
        # interface.
        #
        # See #find_tasks.
	def query_result_set(query)
	    result = ValueSet.new
	    call(:query_result_set, query) do |marshalled_set|
		for task in marshalled_set
		    task = local_object(task)
		    Distributed.keep.ref(task)
		    result << task
		end
	    end

	    result
	end
	
        # Yields the tasks saved in +result_set+ by #query_result_set.  During
        # the enumeration, the tasks are marked as permanent to avoid plan GC.
        # The block can subscribe to the one that are interesting. After the
        # block has returned, all non-subscribed tasks will be subject to plan
        # GC.
	def query_each(result_set) # :nodoc:
	    result_set.each do |task|
		yield(task)
	    end

	ensure
	    Roby.synchronize do
		if result_set
		    result_set.each do |task|
			Distributed.keep.deref(task)
		    end
		end
	    end
	end

	# call-seq:
	#   peer.on(matcher) { |task| ... }	=> ID
	#
	# Call the provided block in the control thread when a task matching
	# +matcher+ has been found on the remote plan. +task+ is the local
	# proxy for the matching remote task.
	#
	# The return value is an identifier which can be later used to remove
	# the trigger with Peer#remove_trigger
        #
        # This sends the PeerServer#add_trigger message to the peer.
	def on(matcher, &block)
	    triggers[matcher.object_id] = [matcher, block]
	    transmit(:add_trigger, matcher.object_id, matcher)
	end

        # Remove a trigger referenced by its ID. +id+ is the value returned by
        # Peer#on
        #
        # This sends the PeerServer#remove_trigger message to the peer.
	def remove_trigger(id)
	    transmit(:remove_trigger, id)
	    triggers.delete(id)
	end

	# Calls the block given to Peer#on in a separate thread when +task+ has
	# matched the trigger
	def triggered(id, task) # :nodoc:
	    task = local_object(task)
	    Distributed.keep.ref(task)

            once do
                begin
                    if trigger = triggers[id]
                        trigger.last.call(task)
                    end
                rescue Exception
                    Distributed.warn "#{self}: trigger handler #{trigger.last} failed with #{$!.full_message}"
                ensure
                    Distributed.keep.deref(task)
                end
            end
	end

	# Returns true if this peer owns +object+
	def owns?(object); object.owners.include?(self) end

	# Discovers all objects at a distance +dist+ from +obj+. The object
	# can be either a remote proxy or the remote object itself
	def discover_neighborhood(object, distance)
	    objects = ValueSet.new
	    Roby.condition_variable(true) do |synchro, mutex|
		mutex.synchronize do
                    done = false
		    transmit(:discover_neighborhood, object, distance) do |edges|
			edges = local_object(edges)
			edges.each do |rel, from, to, info|
			    objects << from.root_object << to.root_object
			end
			Distributed.update_all(objects) do
			    edges.each do |rel, from, to, info|
				from.add_child_object(to, rel, info)
			    end
			end

			objects.each { |obj| Distributed.keep.ref(obj) }
			
                        done = true
			synchro.broadcast
		    end
                    while !done
                        synchro.wait(mutex)
                    end
		end
	    end

	    yield(local_object(remote_object(object)))

	    Roby.synchronize do
		objects.each { |obj| Distributed.keep.deref(obj) }
	    end
	end

        attr_reader :connection_state

        def register_connection_request(request)
            if @pending_connection_request && @pending_connection_request < request
                @pending_connection_request.callbacks.concat(request.callbacks)
                false
            else
                @pending_connection_request = request
                true
            end
        end

        def aborted_connection_request(request, reason: nil)
            if @pending_connection_request == request
                @connection_state = :disconnected
                @pending_connection_request = nil
                if reason
                    Roby.log_error(reason, Distributed, :warn)
                end
            end
        end

        def close
            @pending_connection_request = nil
            @connection_state = :disconnected

            if socket
                socket.close
            end

            if task
                task.stop_event.emit
            end
        end

        class UnknownConnectionRequest < RuntimeError; end

        # Called by {ConnectionSpace#handle_connection_request} to process a
        # request for connection for this peer.
        #
        # @param [Socket] socket the socket on which the request was received
        # @param [Symbol] m the connection method (either :connect or
        #   :reconnect)
        # @param [ConnectionRequest::ConnectionToken] remote_token the token
        #   that will allow us to deterministically decide which connection to
        #   keep in case of concurrent connections
        # @param [Roby::OpenStruct] remote_state the remote Roby state
        #
        # @return [Array,Boolean] the reply that should be sent to the remote
        #   peer, and a boolean that says whether this object took ownership of
        #   the socket (true) or not (false).
        def handle_connection_request(socket, m, remote_name, remote_token, remote_state)
            Distributed.debug { "#{self}: handling connection request #{m.inspect} from #{remote_name} on local:#{socket.local_address.ip_unpack} remote:#{socket.remote_address.ip_unpack}" }
            if connection_state == :connected
                return [:already_connected], false
            elsif @pending_connection_request 
                if remote_token < @pending_connection_request.token
                    @pending_connection_request = nil
                else
                    return [:already_connecting], false
                end
            end

            if m == :connect || m == :reestablish_link
                @connection_state = :connected
                @remote_name = remote_name
                reply = if m == :connect then :connected
                        else :link_reestablished
                        end
                send(reply, socket, remote_state)
                return [reply, remote_id.uri, remote_id.ref, connection_space.state], true
            end

            raise UnknownConnectionRequest, "invalid connection request #{m.inspect} received"
        end

        class StateMismatch < RuntimeError; end

        def connect
            if connection_state != :disconnected
                raise StateMismatch, "trying to establish connection on a peer that is not disconnected"
            end

            connection_space.register_peer(self)
            @connection_state = :connecting
            ConnectionRequest.connect(self) do |request, socket, remote_uri, remote_port, remote_state|
                if @pending_connection_request == request
                    connected(socket, remote_state)
                    yield if block_given?
                end
            end
        end

        def reestablish_link
            if connection_state == :disconnected
                raise StateMismatch, "trying to reestablish connection on a peer that is not connected"
            elsif connection_state != :link_lost
                raise StateMismatch, "connection is not broken"
            end

            @connection_state = :connecting
            ConnectionRequest.reconnect(self) do |request, socket, remote_uri, remote_port, remote_state|
                if @pending_connection_request == request
                    link_reestablished(socket, remote_state)
                    yield if block_given?
                end
            end
        end

        # Wait for the link to become alive
        def wait_link_alive
            wait_link_alive_sync.synchronize do
                while !disconnected? && !link_alive?
                    Distributed.warn "#{self}: link lost, waiting"
                    wait_link_alive_cond.wait(wait_link_alive_sync)
                end
                socket
            end
        end

        # Called when we managed to reconnect to our peer. +socket+ is the new communication socket
        def connected(socket, remote_state)
            Distributed.debug { "#{self}: connected" }
            register_link(socket)
            local_server.state_update remote_state
            @send_queue = Queue.new
	    @send_thread = Thread.new(&method(:communication_loop))
        end

        def link_reestablished(socket, remote_state)
            Distributed.debug { "#{self}: link reestablished" }
            register_link(socket)
            local_server.state_update remote_state
        end

        def register_link(socket)
            if @pending_connection_request
                @pending_connection_request = nil
            end

            wait_link_alive_sync.synchronize do
                @socket      = socket
                @connection_state = :connected
                connection_space.register_link(self, socket)

                wait_link_alive_cond.broadcast
            end
            Distributed.debug { "#{self}: registered link #{socket} local:#{socket.local_address.ip_unpack} remote:#{socket.remote_address.ip_unpack}" }
        end

        def link_lost
            Distributed.info "#{self}: link lost"
            @socket = nil
            @connection_state = :link_lost
        end

        # Normal disconnection procedure. 
        #
        # The procedure is as follows:
        # * we set the connection state as 'disconnecting'. This disables all
        #   notifications for this peer (see for instance
        #   Distributed.each_subscribed_peer)
        # * we queue the :disconnected message
        #
        # At this point, we are waiting for the remote peer to do the same:
        # send us 'disconnected'. When we receive that message, we put the
        # connection into the disconnected state and all transmission is
        # forbidden. We make the transmission thread quit then, and the
        # 'failed' event is emitted on the ConnectionTask task
        #
        # Note that once the connection leaves the connected state, the only
        # messages allowed by #queue_call are 'completed' and 'disconnected'
        def disconnect
            if !connected?
                raise StateMismatch, "attempting to disconnect a non-connected peer"
            end

            Distributed.info "#{self}: disconnecting"
            @connection_state = :disconnecting
            queue_call false, :disconnect
        end

        # +error+ has been raised while we were processing +msg+(*+args+)
        # This error cannot be recovered, and the connection to the peer
        # will be closed.
        #
        # This sends the PeerServer#fatal_error message to our peer
        def fatal_error(error, msg, args)
            Distributed.fatal "#{self}: fatal error '#{error.message}' while processing #{msg}(#{args.join(", ")})"
            Distributed.fatal Roby.filter_backtrace(error.backtrace).join("\n  ")
            @connection_state = :disconnecting
            queue_call false, :fatal_error, [error, msg, args]
        end

        # Called when the peer acknowledged the fact that we disconnected
        def disconnected(event = :failed) # :nodoc:
            task.emit(event)
            connection_space.deregister_peer(self)

            wait_link_alive_sync.synchronize do
                @connection_state = :disconnected
                @send_queue.clear
                @send_queue.push nil
                @send_thread.join
                @send_queue, @send_thread = nil
                socket.close if !socket.closed?
                @socket = nil

                wait_link_alive_cond.broadcast
            end

            self.clear
            Distributed.info "#{self}: disconnected (#{event})"
        end

        # Call to disconnect outside of the normal protocol.
        def disconnected!
            disconnected(:aborted)
        end

        # Returns true if the connection has been established. See also #link_alive?
        def connected?; connection_state == :connected end
        # Returns true if the we disconnected on our side but the peer did not
        # acknowledge it yet
        def disconnecting?; connection_state == :disconnecting end
        # Returns true if we are not connected with this peer
        def disconnected?; connection_state == :disconnected end

        # Returns true if we are communicating with this peer
        def communicates?; !disconnected?  end

        # Mark the link as dead regardless of the last neighbour discovery. This
        # will be reset during the next neighbour discovery
        def link_dead!; @dead = true end
        
        # Disables the sending part of the communication link. It is an
        # accumulator: if #disable_tx is called twice, then TX will be
        # reenabled only when #enable_tx is also called twice.
        def disable_tx; @disabled_tx += 1 end
        # Enables the sending part of the communication link. It is an
        # accumulator: if #enable_tx is called twice, then TX will be
        # disabled only when #disable_tx is also called twice.
        def enable_tx; @disabled_tx -= 1 end
        # True if TX is currently disabled
        def disabled_tx?; @disabled_tx > 0 end
        # Disables the receiving part of the communication link. It is an
        # accumulator: if #disable_rx is called twice, then RX will be
        # reenabled only when #enable_rx is also called twice.
        def disable_rx; @disabled_rx += 1 end
        # Enables the receiving part of the communication link. It is an
        # accumulator: if #enable_rx is called twice, then RX will be
        # disabled only when #disable_rx is also called twice.
        def enable_rx; @disabled_rx -= 1 end
        # True if RX is currently disabled
        def disabled_rx?; @disabled_rx > 0 end

        # Checks if the connection is currently alive, i.e. if we can send
        # data on the link. This does not mean that we currently have no
        # interaction with the peer: it only means that we cannot currently
        # communicate with it.
        def link_alive?
            !!socket && !@dead && @disabled_tx == 0
        end

        # The main synchronization mutex to access the peer. See also
        # Peer#synchronize
        attr_reader :mutex
        def synchronize; @mutex.synchronize { yield } end

        # The transmission thread
        attr_reader :send_thread
        # The queue which holds all calls to the remote peer. Calls are
        # saved as CallSpec objects
        attr_reader :send_queue
        # The queue of calls that have been sent to our peer, but for which
        # a +completed+ message has not been received. This is a queue of
        # CallSpec objects
        attr_reader :completion_queue
        # The cycle data which is being gathered before queueing it into #send_queue
        attr_reader :current_cycle

        @@message_id = 0

        # Checks that +object+ is marshallable. If +object+ is a
        # collection, it will check that each of its elements is
        # marshallable first. This is automatically called for all
        # messages if DEBUG_MARSHALLING is set to true.
        def check_marshallable(object, stack = ValueSet.new)
            if !object.kind_of?(DRbObject) && object.respond_to?(:each) && !object.kind_of?(String)
                if stack.include?(object)
                    Distributed.warn "recursive marshalling of #{obj}"
                    raise "recursive marshalling"
                end

                stack << object
                begin
                    object.each do |obj|
                        marshalled = begin
                                         check_marshallable(obj, stack)
                                     rescue Exception
                                         raise TypeError, "cannot dump #{obj}(#{obj.class}): #{$!.message}"
                                     end

                            
                        if Marshal.load(marshalled).kind_of?(DRb::DRbUnknown)
                            raise TypeError, "cannot load #{obj}(#{obj.class})"
                        end
                    end
                ensure
                    stack.delete(object)
                end
            end
            Marshal.dump(object)
        end

        # This set of calls mark the end of a cycle. When one of these is
        # encountered, the calls gathered in #current_cycle are moved into
        # #send_queue
        CYCLE_END_CALLS = [:connect, :disconnect, :fatal_error, :state_update]

        attr_predicate :sync?, true
        
        # Add a CallSpec object in #send_queue. Do not use that method
        # directly, but use #transmit and #call instead.
        #
        # The message to be sent is m(*args).  +on_completion+ is either
        # nil or a block object which should be called once the message has
        # been processed by our remote peer. +waiting_thread+ is a Thread
        # object of a thread waiting for the message to be processed.
        # #raise will be called on it if an error has occured during the
        # remote processing.
        #
        # If +is_callback+ is true, it means that the message is being
        # queued during the processing of another message. In that case, we
        # will receive the completion message only when all callbacks have
        # also been processed. Queueing callbacks while processing another
        # callback is forbidden and the communication layer raises
        # RecursiveCallbacksError if it happens.
        #
        # #queueing allow to queue normal messages when they would have
        # been marked as callbacks.
        def queue_call(is_callback, m, args = [], on_completion = nil, waiting_thread = nil)
            # Do some sanity checks
            if !m.respond_to?(:to_sym)
                raise ArgumentError, "method argument should be a symbol, was #{m.class}"
            end

            # Check the connection state
            if (disconnecting? && m != :disconnect && m != :fatal_error) || disconnected?
                raise DisconnectedError, "cannot queue #{m}(#{args.join(", ")}), we are not currently connected to #{remote_name}"
            end

            # Marshal DRoby-dumped objects now, since the object may be
            # modified between now and the time it is sent
            formatted_args = Distributed.format(args, self)

            if Roby::Distributed::DEBUG_MARSHALLING
                check_marshallable(formatted_args)
            end
            
            call_spec = CallSpec.new(is_callback, 
                                     m, formatted_args, args, 
                                     on_completion, caller(2), waiting_thread)

            synchronize do
                # No return message for 'completed' (of course)
                if call_spec.method != :completed
                    @@message_id += 1
                    call_spec.message_id = @@message_id
                    completion_queue << call_spec

                elsif !current_cycle.empty? && !(args[0] || args[1])
                    # Try to merge empty completed messages
                    last_call = current_cycle.last
                    last_method, last_args = last_call[1], last_call[2]

                    case last_method
                    when :completed
                        if !(last_args[0] || last_args[1])
                            Distributed.debug "#{self}: merging two completion messages"
                            current_cycle.pop
                            call_spec.method = :completion_group
                            call_spec.formatted_args = [last_args[2], args[2]]
                        end
                    when :completion_group
                        Distributed.debug "#{self}: extending a completion group"
                        current_cycle.pop
                        call_spec.method = :completion_group
                        call_spec.formatted_args = [last_args[0], args[2]]
                    end
                end

                Distributed.debug { "#{self}: #{call_spec.is_callback ? 'adding callback' : 'queueing'} [#{call_spec.message_id}]#{remote_name}.#{call_spec.method}" }
                current_cycle    << [call_spec.is_callback, call_spec.method, call_spec.formatted_args, !waiting_thread, call_spec.message_id]
                if sync? || CYCLE_END_CALLS.include?(m)
                    Distributed.debug "#{self}: transmitting #{@current_cycle.size} calls"
                    send_queue << current_cycle
                    @current_cycle = Array.new
                end
            end
        end

        # If #transmit calls are done in the block given to #queueing, they
        # will queue the call normally, instead of marking it as callback
        def queueing
            old_processing = local_server.processing?

            local_server.processing = false
            yield

        ensure
            local_server.processing = old_processing
        end

        # call-seq:
        #   peer.transmit(method, arg1, arg2, ...) { |ret| ... }
        #
        # Asynchronous call to the remote host. If a block is given, it is
        # called in the communication thread when the call succeeds, with
        # the returned value as argument.
        def transmit(m, *args, &block)
            is_callback = execution_engine.inside_control? && local_server.processing?
            if is_callback && local_server.processing_callback?
                raise RecursiveCallbacksError, "cannot queue callback #{m}(#{args.join(", ")}) while serving one"
            end
            
            queue_call is_callback, m, args, block
        end

        # call-seq:
        #	peer.call(method, arg1, arg2)	    => result
        #
        # Calls a method synchronously and returns the value returned by
        # the remote server. If we disconnect before this call is
        # processed, raises DisconnectedError. If the remote server returns
        # an exception, this exception is raised in the calling thread as
        # well.
        #
        # Note that it is forbidden to use this method in control or
        # communication threads, as it would make the application deadlock
        def call(m, *args, &block)
            if !execution_engine.outside_control? || Roby.taken_global_lock?
                raise "cannot use Peer#call in control thread or while taking the Roby global lock"
            end

            result = nil
            Roby.condition_variable(true) do |cv, mt|
                mt.synchronize do
                    Distributed.debug do
                        "#{self}: calling #{m}"
                    end

                    called = false
                    callback = Proc.new do |return_value|
                        mt.synchronize do
                            result = return_value
                            block.call(return_value) if block
                            called = true
                            cv.broadcast
                        end
                    end

                    queue_call false, m, args, callback, Thread.current
                    until called
                        cv.wait(mt)
                    end
                end
            end

            result
        end

        # Main loop of the thread which communicates with the remote peer
        def communication_loop
            id = 0
            marshalled_data = String.new
            buffer = StringIO.new(" " * 8, 'w')

            Distributed.debug "#{self}: starting communication loop"

            loop do
                socket = wait_link_alive
                if disconnected?
                    return
                elsif marshalled_data.empty?
                    data = send_queue.shift
                    return if !data

                    buffer.truncate(8)
                    buffer.seek(8)
                    Marshal.dump(data, buffer)
                    buffer.string[0, 8] = [id += 1, buffer.size - 8].pack("NN")
                    marshalled_data = buffer.string.dup
                end

                size = marshalled_data.size
                Distributed.debug { "#{self}: sending ID=#{id} #{size}B" }

                begin
                    written_bytes = socket.write_nonblock(marshalled_data)
                    stats.tx += written_bytes
                    marshalled_data = marshalled_data[written_bytes..-1]

                rescue IO::WaitWritable
                rescue Errno::EPIPE, Errno::ECONNRESET, IOError
                    # communication error. We leave the handling of this to the
                    # read thread
                    socket.close if !socket.closed?
                    connection_space.trigger_receive_loop("N")
                end
            end

        rescue Exception => e
            Distributed.fatal do
                "#{self}: While sending #{data.inspect}\n" +
                "#{self}: Communication thread dies with\n#{e.full_message}"
            end

            disconnected!

        ensure
            Distributed.info "#{self}: communication thread quitting. Rx: #{stats.rx}B, Tx: #{stats.tx}B"
            calls = []
            while !completion_queue.empty?
                calls << completion_queue.shift
            end

            calls.each do |call_spec|
                next unless call_spec
                if thread = call_spec.waiting_thread
                    thread.raise DisconnectedError
                end
            end

            Distributed.info "#{self}: communication thread quit"
        end

        # Formats an error message because +error+ has been reported by +call+
        def report_remote_error(call, error)
            error_message = error.full_message { |msg| msg !~ /drb\/[\w+]\.rb/ }
            if call
                "#{remote_name} reports an error on #{call}:\n#{error_message}\n" +
                "call was initiated by\n  #{call.trace.join("\n  ")}"
            else
                "#{remote_name} reports an error on:\n#{error_message}"
            end
        end

        # Calls the completion block that has been given to #transmit when
        # +call+ is completed (the +on_completion+ parameter of
        # #queue_call). A remote call is completed when it has been
        # processed remotely *and* the callbacks returned by the remote
        # server (if any) have been processed as well. +result+ is the
        # value returned by the remote server.
        def call_attached_block(call, result)
            if block = call.on_completion
                begin
                    Distributed.debug "#{self}: calling completion block #{block} for #{call}"
                    block.call(result)
                rescue Exception => e
                    Roby.application_error(:droby_callbacks, block, e)
                end
            end
        end

        def synchro_point; call(:synchro_point) end

        # An intermediate representation of Peer objects suitable to be
        # sent to our peers.
        class DRoby # :nodoc:
            attr_reader :name, :peer_id
            def initialize(name, peer_id); @name, @peer_id = name, peer_id end
            def hash; peer_id.hash end
            def eql?(obj); obj.respond_to?(:peer_id) && peer_id == obj.peer_id end
            alias :== :eql?

            def to_s; "#<dRoby:Peer #{name} #{peer_id}>" end 
            def proxy(peer)
                if peer = Distributed.peer(peer_id)
                    peer
                else
                    raise "unknown peer ID #{peer_id}, known peers are #{Distributed.peers}"
                end
            end
        end
    
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
        def droby_dump(dest = nil)
            @__droby_marshalled__ ||= DRoby.new(remote_name, remote_id)
        end

        # Creates a sibling for +object+ on the peer, and returns the corresponding
        # DRbObject
        def create_sibling(object)
            unless object.kind_of?(DistributedObject)
                raise TypeError, "cannot create a sibling for a non-distributed object"
            end

            call(:create_sibling, object)
            subscriptions << object.sibling_on(self)
            Roby.synchronize do
                local_server.subscribe(object)
            end

            synchro_point
        end

        # The set of remote objects we *want* notifications on, as
        # RemoteID objects. This does not include automatically susbcribed
        # objects, but only those explicitely subscribed to by calling
        # Peer#subscribe
        #
        # See also #subscribe, #subscribed? and #unsubscribe
        #
        #--
        # DO NOT USE a ValueSet here. RemoteIDs must be compared using #==
        #++
        attribute(:subscriptions) { Set.new }

        # Explicitely subscribe to #object
        #
        # See also #subscriptions, #subscribed? and #unsubscribe
        def subscribe(object)
            while object.respond_to?(:__getobj__)
                object = object.__getobj__
            end

            if remote_object = (remote_object(object) rescue nil)
                if !subscriptions.include?(remote_object)
                    remote_object = nil
                end
            end

            unless remote_object
                remote_sibling = object.sibling_on(self)
                remote_object = call(:subscribe, remote_sibling)
                synchro_point
            end
            local_object = local_object(remote_object)
        end

        # Make our peer subscribe to +object+
        def push_subscription(object)
            local_server.subscribe(object)
            synchro_point
        end

        # The RemoteID for the peer main plan
        attr_accessor :remote_plan

        # Subscribe to the remote plan
        def subscribe_plan
            call(:subscribe_plan, connection_space.plan.remote_id)
            synchro_point
        end

        # Unsubscribe from the remote plan
        def unsubscribe_plan
            proxies.delete(remote_plan)
            subscriptions.delete(remote_plan)
            if connected?
                call(:removed_sibling, @remote_plan, connection_space.plan.remote_id)
            end
        end
        
        def subscribed_plan?; remote_plan && subscriptions.include?(remote_plan) end

        # True if we are explicitely subscribed to +object+. Automatically
        # subscribed objects will not be included here, but
        # BasicObject#updated? will return true for them
        #
        # See also #subscriptions, #subscribe and #unsubscribe
        def subscribed?(object)
            subscriptions.include?(remote_object(object))
        rescue RemotePeerMismatch
            false
        end

        # Remove an explicit subscription. See also #subscriptions,
        # #subscribe and #subscribed?
        #
        # See also #subscriptions, #subscribe and #subscribed?
        def unsubscribe(object)
            subscriptions.delete(remote_object(object))
        end

        # Send the information related to the given transaction in the
        # remote plan manager.
        def transaction_propose(trsc)
            synchro_point
            create_sibling(trsc)
            nil
        end

        # Give the edition token on +trsc+ to the given peer.
        # +needs_edition+ is a flag which, if true, requests that the token
        # is given back at least once to the local plan manager.
        #
        # Do not use this directly, it is part of the multi-robot
        # communication protocol. Use the edition-related methods on
        # Distributed::Transaction instead.
        def transaction_give_token(trsc, needs_edition)
            call(:transaction_give_token, trsc, needs_edition)
        end

        def once(&block)
            execution_engine.once(&block)
        end
    end

    end
end

