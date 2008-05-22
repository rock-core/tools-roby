module Roby
    module Distributed
        # Error raised when a connection attempt failed on the given neighbour
	class ConnectionFailed < RuntimeError
	    attr_reader :neighbour

	    def initialize(neighbour)
		@neighbour = neighbour
	    end
	end

	class Peer
	    class << self
		private :new
	    end

            # ConnectionToken objects are used to sort out concurrent
            # connections, i.e. cases where two peers are trying to initiate a
            # connection with each other at the same time.
            #
            # When this situation appears, each peer compares its own token
            # with the one sent by the remote peer. The greatest token wins and
            # is considered the initiator of the connection.
            #
            # See #initiate_connection
	    class ConnectionToken
		attr_reader :time, :value
		def initialize
		    @time  = Time.now
		    @value = rand
		end
		def <=>(other)
		    result = (time <=> other.time)
		    if result == 0
			value <=> other.value
		    else
			result
		    end
		end
		include Comparable
	    end

	    # A value indicating the current status of the connection. It can
	    # be one of :connected, :disconnecting, :disconnected
	    attr_reader :connection_state

	    # Connect to +neighbour+ and return the corresponding peer. It is a
	    # blocking method, so it is an error to call it from within the control thread
	    def self.connect(neighbour)
		Roby.condition_variable(true) do |cv, mutex|
		    peer = nil
		    mutex.synchronize do
			thread = initiate_connection(Distributed.state, neighbour) do |peer|
			    return peer unless thread
			end

			begin
			    mutex.unlock
			    thread.value
			rescue Exception => e
			    connection_space.synchronize do
				connection_space.pending_connections.delete(neighbour.remote_id)
			    end
			    raise ConnectionFailed.new(neighbour), e.message
			ensure
			    mutex.lock
			end
		    end
		end
	    end
	    
	    # Start connecting to +neighbour+ in an another thread and yield
	    # the corresponding Peer object. This is safe to call if we have
	    # already connected to +neighbour+, in which case the already
	    # existing peer is returned.
	    #
	    # The Peer object is yield from within the control thread, only
	    # when the :ready event of the peer's ConnectionTask has been
	    # emitted
	    #
	    # Returns the connection thread
	    def self.initiate_connection(connection_space, neighbour, &block)
		connection_space.synchronize do
		    if peer = connection_space.peers[neighbour.remote_id]
			# already connected
			yield(peer) if block_given?
			return
		    end

		    local_token = ConnectionToken.new
		    call = [:connect, local_token,
			connection_space.name,
			connection_space.remote_id, 
			Distributed.format(Roby::State)]
		    send_connection_request(connection_space, neighbour, call, local_token, &block)
		end
	    end

	    def self.abort_connection_thread(connection_space, remote_id, lock = true)
		if lock
		    connection_space.synchronize do
			abort_connection_thread(connection_space, remote_id, false)
		    end
		end

		connection_space.pending_connections.delete(remote_id)
		if peer = connection_space.peers[remote_id]
		    begin
			connection_space.mutex.unlock
			peer.disconnected(:aborted)
		    ensure
			connection_space.mutex.lock
		    end
		end
	    end

	    def self.send_connection_thread(connection_space, neighbour, call, local_token, &block)
		remote_id = neighbour.remote_id
		Thread.current.abort_on_exception = false

		begin
		    socket = TCPSocket.new(remote_id.uri, remote_id.ref)
		rescue Errno::ECONNRESET, Errno::ECONNREFUSED
		    abort_connection_thread(connection_space, remote_id)
		    return
		end

		begin
		    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
		    Distributed.debug "#{call[0]}: #{neighbour} on #{socket.peer_info}"

		    # Send the connection request
		    call = Marshal.dump(call)
		    socket.write [call.size].pack("N")
		    socket.write call

		    reply_size = socket.read(4)
		    if !reply_size
			raise "peer disconnected"
		    end
		    reply = Marshal.load(socket.read(*reply_size.unpack("N")))
		rescue Errno::ECONNRESET, Errno::ENOTCONN
		    abort_connection_thread(connection_space, remote_id)
		    return
		end

		connection_space.synchronize do
		    connection_space.pending_connections.delete(remote_id)
		    m = reply.shift
		    Roby::Distributed.debug "remote peer #{m}"

		    # if the remote peer is also connecting, and if its
		    # token is better than our own, m will be nil and thus
		    # the thread will finish without doing anything

		    case m
		    when :connected
			peer = new(connection_space, socket, *reply)
		    when :reconnected
			peer = connection_space.peers[remote_id]
			peer.reconnected(socket)
		    when :aborted
			abort_connection_thread(connection_space, remote_id, false)
			return
		    when :already_connecting, :already_connected
			peer = connection_space.peers[remote_id]
		    end

		    yield(peer) if peer && block_given?
		    peer
		end
	    end

	    # Generic handling of connection/reconnection initiated by this side
	    def self.send_connection_request(connection_space, neighbour, call, local_token, &block) # :nodoc:
		remote_id = neighbour.remote_id
		token, connecting_thread = connection_space.pending_connections[remote_id]
		if token
		    # we are already connecting to the peer, check the connection token
		    peer = begin
			       connection_space.mutex.unlock
			       connecting_thread.value
			   ensure
			       connection_space.mutex.lock
			   end

		    if token < local_token
			if !peer
			    raise "something went wrong during connection: got nil peer with better token"
			end
			yield(peer) if block_given?
			return
		    end
		end


		connecting_thread = Thread.new do
		    send_connection_thread(connection_space, neighbour, call, local_token, &block)
		end
		connection_space.pending_connections[remote_id] = [local_token, connecting_thread]
		connecting_thread
	    end

	    # Create a Peer object for a connection attempt on the server
	    # socket There is nothing to do here. The remote peer is supposed
	    # to send us a #connect message, after which we can assume that the
	    # connection is up
	    def self.connection_request(connection_space, socket)
		socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

		# read connection info from +socket+
		info_size = *socket.read(4).unpack("N")
		m, remote_token, remote_name, remote_id, remote_state = 
		    Marshal.load(socket.read(info_size))

		Distributed.debug "connection attempt from #{socket}: #{m} #{remote_name} #{remote_id}"

		connection_space.synchronize do
		    # Now check the connection status
		    if old_peer = connection_space.aborted_connections.delete(remote_id)
			reply = [:aborted]
		    elsif m == :connect && peer = connection_space.peers[remote_id]
			reply = [:already_connected]
		    else
			token, connecting_thread = connection_space.pending_connections[remote_id]
			if token && token < remote_token
			    if connecting_thread
				begin
				    connection_space.mutex.unlock
				    connecting_thread.join
				ensure
				    connection_space.mutex.lock
				end
			    end
			    reply = [:already_connecting]
			elsif m == :reconnect
			    peer = connection_space.peers[remote_id]
			    peer.reconnected(socket)
			    reply = [:reconnected]
			else
			    peer = new(connection_space, socket, remote_name, remote_id, remote_state)
			    reply = [:connected, connection_space.name,
				connection_space.remote_id, 
				Distributed.format(Roby::State)]
			end
		    end

		    Distributed.debug "connection attempt from #{socket}: #{reply[0]}"
		    reply = Marshal.dump(reply)
		    socket.write [reply.size].pack("N")
		    socket.write reply
		end
	    end
	    
	    # Reconnect to the given peer after the socket closed
	    def reconnect
		local_token = ConnectionToken.new

		connection_space.synchronize do
		    call = [:reconnect, local_token, connection_space.name, connection_space.remote_id]
		    Peer.send_connection_request(connection_space, self, call, local_token)
		end
	    end

	    # Called when we managed to reconnect to our peer. +socket+ is the new communication socket
	    def reconnected(socket)
		Roby::Distributed.debug "new socket for #{self}: #{socket.peer_info}"
		connection_space.pending_sockets << [socket, self]
		@socket = socket
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
		synchronize do
		    Roby::Distributed.info "disconnecting from #{self}"
		    @connection_state = :disconnecting
		end
		queue_call false, :disconnect
	    end

            # +error+ has been raised while we were processing +msg+(*+args+)
            # This error cannot be recovered, and the connection to the peer
            # will be closed.
            #
            # This sends the PeerServer#fatal_error message to our peer
	    def fatal_error(error, msg, args)
		synchronize do
		    Roby::Distributed.fatal "fatal error '#{error.message}' while processing #{msg}(#{args.join(", ")})"
		    Roby::Distributed.fatal Roby.filter_backtrace(error.backtrace).join("\n  ")
		    @connection_state = :disconnecting
		end
		queue_call false, :fatal_error, [error, msg, args]
	    end

	    # Called when the peer acknowledged the fact that we disconnected
	    def disconnected(event = :failed) # :nodoc:
		Roby::Distributed.info "#{remote_name} disconnected (#{event})"

		connection_space.synchronize do
		    Distributed.peers.delete(remote_id)
		end

		synchronize do
		    @connection_state = :disconnected

		    if @send_thread && @send_thread != Thread.current
			begin
			    @send_queue.clear
			    @send_queue.push nil
			    mutex.unlock
			    @send_thread.join
			ensure
			    mutex.lock
			end
		    end
		    @send_thread = nil

		    proxies.each_value do |obj|
			obj.remote_siblings.delete(self)
		    end
		    proxies.clear
		    removing_proxies.clear

		    socket.close unless socket.closed?
		end

		Roby.once do
		    task.emit(event)
		end
	    end

	    # Call to disconnect outside of the normal protocol.
	    def disconnected!
		connection_space.synchronize do
		    connection_space.aborted_connections[remote_id] = self
		end
		disconnected(:aborted)
	    end

	    # Returns true if the connection has been established. See also #link_alive?
	    def connected?; connection_state == :connected end
	    # Returns true if the we disconnected on our side but the peer did not
	    # acknowledge it yet
	    def disconnecting?; connection_state == :disconnecting end
	    # Returns true if the connection with this peer has been removed
	    def disconnected?; connection_state == :disconnected end

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
		return false if socket.closed? || @dead || @disabled_tx > 0
		return false unless !remote_id || connection_space.neighbours.find { |n| n.remote_id == remote_id }
		true
	    end

	end

	class PeerServer
            # Message received when an error occured on the remote side, if
            # this error cannot be recovered.
	    def fatal_error(error, msg, args)
		Distributed.fatal "remote reports #{peer.local_object(error)} while processing #{msg}(#{args.join(", ")})"
		disconnect
	    end

            # Message received when our peer is closing the connection
	    def disconnect
		peer.disconnected
		nil
	    end
	end

        # Error raised when a communication callback is queueing another
        # communication callback
	class RecursiveCallbacksError < RuntimeError; end
        # Error raised when a callback has failed.
	class CallbackProcessingError < RuntimeError; end

	CallSpec = Struct.new :is_callback, 
	    :method, :formatted_args, :original_args,
	    :on_completion, :trace, :waiting_thread,
	    :message_id

	# The specification of a call in Peer#send_queue and Peer#completion_queue. Note
	# that only the #is_callback, #method and #formatted_args are sent to the remote
	# PeerServer#demux method
	#
	# * is_callback is a boolean flag indicating if this call has been
	#   queued while the PeerServer object was processing a remote request
	# * <tt>method</tt> is the method name to call on the remote PeerServer object
	# * <tt>formatted_args</tt> is the arguments formatted by
	#   Distributed.format.  Arguments are formatted right away, since we
	#   want the marshalled arguments to reflect objects state at the
	#   time of the call, not at the time they are sent
	# * +original_args+ is the arguments not yet formatted. They are
	#   kept here to protect involved object from Ruby's GC until the
	#   call is completed.
	# * +on_completion+ is a proc object which will be called when the
	#   method has successfully been processed by the remote object, with
	#   the returned value as argument$
	# * trace is the location (as returned by Kernel#caller) from which
	#   the call has been queued. It is mainly used for debugging
	#   purposes
	# * if +thread+ is not nil, it is the thread which is waiting for
	#   the call to complete. If the call is aborted, the error will be
	#   raised in the waiting thread
	class CallSpec
	    alias :callback? :is_callback

	    def to_s
		args = formatted_args.map do |arg|
		    if arg.kind_of?(DRbObject) then arg.inspect
		    else arg.to_s
		    end
		end
		"#{method}(#{args.join(", ")})"
	    end
	end

        # Called in PeerServer messages handlers to completely ignore the
        # message which is currently being processed
	def self.ignore!
	    throw :ignore_this_call
	end

	class PeerServer
	    # True the current thread is processing a remote request
	    attr_predicate :processing?, true
	    # True if the current thread is processing a remote request, and if it is a callback
	    attr_predicate :processing_callback?, true
	    # True if we have already queued a +completed+ message for the message being processed
	    attr_predicate :queued_completion?, true
	    # The ID of the message we are currently processing
	    attr_accessor :current_message_id

            # Message received when the first half of a synchro point is
            # reached. See Peer#synchro_point.
	    def synchro_point
		peer.transmit(:done_synchro_point)
		nil
	    end
            # Message received when the synchro point is finished.
	    def done_synchro_point; end

            # Message received to describe a group of consecutive calls that
            # have been completed, when all those calls return nil. This is
            # simply an optimization of the communication protocol, as most
            # remote calls return nil.
            #
            # +from_id+ is the ID of the first call of the group and +to_id+
            # the last. Both are included in the group.
	    def completion_group(from_id, to_id)
		for id in (from_id..to_id)
		    completed(nil, nil, id)
		end
		nil
	    end

            # Message received when a given call, identified by its ID, has
            # been processed on the remote peer.  +result+ is the value
            # returned by the method, +error+ an exception object (if an error
            # occured).
	    def completed(result, error, id)
		call_spec = peer.completion_queue.pop
		if call_spec.message_id != id
		    result = Exception.exception("something fishy: ID mismatch in completion queue (#{call_spec.message_id} != #{id}")
		    error  = true
		    call_spec = nil
		end
		if error
		    if call_spec && thread = call_spec.waiting_thread
			result = peer.local_object(result)
			thread.raise result
		    else
			Roby::Distributed.fatal "fatal error in communication with #{peer}: #{result.full_message}"
			Roby::Distributed.fatal "disconnecting ..."
			if peer.connected?
			    peer.disconnect
			else
			    peer.disconnected!
			end
		    end

		elsif call_spec
		    peer.call_attached_block(call_spec, result)
		end

		nil
	    end

	    # Queue a completion message for our peer. This is usually done
	    # automatically in #demux, but it is useful to do it manually in
	    # certain conditions, for instance in PeerServer#execute
	    #
	    # In #execute, the control thread -> RX thread context switch is
	    # not immediate. Therefore, it is possible that events are queued
	    # by the control thread while the #completed message is not.
	    # #completed! both queues the message *and* makes sure that #demux
	    # won't.
	    def completed!(result, error)
		if queued_completion?
		    raise "already queued the completed message"
		else
		    Distributed.debug { "done, returns #{'error ' if error}#{result || 'nil'} in completed!" }
		    self.queued_completion = true
		    peer.queue_call false, :completed, [result, error, current_message_id]
		end
	    end

	    # call-seq:
	    #	execute { ... }
	    #
	    # Executes the given block in the control thread and return when the block
	    # has finished its execution. This method can be called only when serving
	    # a remote call.
	    def execute
		if !processing?
		    return yield
		end

		Roby.execute do
		    error = nil
		    begin
			result = yield
		    rescue Exception => error
		    end
		    completed!(error || result, !!error, peer.current_message_id)
		end
	    end
	end

	class Peer
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
			Roby.warn "recursive marshalling of #{obj}"
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
				Distributed.debug "merging two completion messages"
				current_cycle.pop
				call_spec.method = :completion_group
				call_spec.formatted_args = [last_args[2], args[2]]
			    end
			when :completion_group
			    Distributed.debug "extending a completion group"
			    current_cycle.pop
			    call_spec.method = :completion_group
			    call_spec.formatted_args = [last_args[0], args[2]]
			end
		    end

		    Distributed.debug { "#{call_spec.is_callback ? 'adding callback' : 'queueing'} [#{call_spec.message_id}]#{remote_name}.#{call_spec.method}" }
		    current_cycle    << [call_spec.is_callback, call_spec.method, call_spec.formatted_args, !waiting_thread, call_spec.message_id]
		    if sync? || CYCLE_END_CALLS.include?(m)
                        Distributed.debug "transmitting #{@current_cycle.size} calls"
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
		is_callback = Roby.inside_control? && local_server.processing?
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
		if !Roby.outside_control? || Roby.taken_global_lock?
		    raise "cannot use Peer#call in control thread or while taking the Roby::Control mutex"
		end

		result = nil
		Roby.condition_variable(true) do |cv, mt|
		    mt.synchronize do
			Distributed.debug do
			    "calling #{remote_name}.#{m}"
			end

			callback = Proc.new do |return_value|
			    mt.synchronize do
				result = return_value
				block.call(return_value) if block
				cv.broadcast
			    end
			end

			queue_call false, m, args, callback, Thread.current
			cv.wait(mt)
		    end
		end

		result
	    end

	    # Main loop of the thread which communicates with the remote peer
	    def communication_loop
		Thread.current.priority = 2
		id = 0
		data   = nil
		buffer = StringIO.new(" " * 8, 'w')

                Roby::Distributed.debug "starting communication loop to #{self}"

		loop do
		    data ||= send_queue.shift
		    return if disconnected?

		    # Wait for the link to be alive before sending anything
		    while !link_alive?
			return if disconnected?
                        Roby::Distributed.info "#{self} is out of reach. Waiting before transmitting"
			connection_space.wait_next_discovery
		    end
		    return if disconnected?

		    buffer.truncate(8)
		    buffer.seek(8)
		    Marshal.dump(data, buffer)
		    buffer.string[0, 8] = [id += 1, buffer.size - 8].pack("NN")

		    begin
			size = buffer.string.size
			Roby::Distributed.debug { "sending #{size}B to #{self}" }
			stats.tx += size
			socket.write(buffer.string)

			data = nil
		    rescue Errno::EPIPE
			@dead = true
			# communication error, retry sending the data (or, if we are disconnected, return)
		    end
		end

	    rescue Interrupt
	    rescue Exception
		Distributed.fatal do
		    "While sending #{data.inspect}\n" +
		    "Communication thread dies with\n#{$!.full_message}"
		end

		disconnected!

	    ensure
		Distributed.info "communication thread quitting for #{self}. Rx: #{stats.rx}B, Tx: #{stats.tx}B"
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

		Distributed.info "communication thread quit for #{self}"
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
			Roby::Distributed.debug "calling completion block #{block} for #{call}"
			block.call(result)
		    rescue Exception => e
			Roby.application_error(:droby_callbacks, block, e)
		    end
		end
	    end

	    def synchro_point; call(:synchro_point) end
	end
    end
end
