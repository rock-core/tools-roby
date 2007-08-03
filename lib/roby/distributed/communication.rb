module Roby
    module Distributed
	class ConnectionSpace

	end

	class Peer
	    class << self
		private :new
	    end

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
	    # be one of :connecting, :connected, :disconnecting, :disconnected
	    attr_reader :connection_state

	    # Start connecting to +neighbour+. We create a socket and create a
	    # Peer object for this neighbour. Then, we call Peer#connect so
	    # that the Peer object queues a #connect call for the remote peer.
	    #
	    # The connection is done when the remote peer returns us a
	    # completion message for this connect message
	    def self.initiate_connection(connection_space, neighbour, &block)
		local_token = ConnectionToken.new
		remote_id = neighbour.remote_id

		connection_space.synchronize do
		    if peer = connection_space.peers[remote_id]
			# already connected
			return peer
		    else
			token, connecting_thread = connection_space.pending_connections[remote_id]
			if token
			    # we are already connecting to the peer, check the connection token
			    peer = connection_thread.value
			    if token < local_token
				if !peer
				    raise "something went wrong during connection: got nil peer with better token"
				end
				return peer
			    end
			end
		    end

		    connecting_thread = Thread.new do
			Thread.current.abort_on_exception = false

			socket = TCPSocket.new(neighbour.remote_id.uri, neighbour.remote_id.ref)
			socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
			Distributed.debug "initiate connection with #{neighbour} on #{socket.peer_info}"

			# Send the connection request
			info = Marshal.dump [:connect, local_token,
			    connection_space.name,
			    connection_space.remote_id, 
			    Distributed.format(Roby::State)]
			socket.write [info.size].pack("N")
			socket.write info

			reply_size = socket.read(4)
			if !reply_size
			    raise "peer disconnected"
			end
			reply = Marshal.load(socket.read(*reply_size.unpack("N")))

			connection_space.synchronize do
			    connection_space.pending_connections.delete(remote_id)
			    if reply.shift == :connect
				new(connection_space, socket, *reply, &block)
			    end
			end
		    end
		    connection_space.pending_connections[remote_id] = [local_token, connecting_thread]
		end
		nil
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
		    elsif peer = connection_space.peers[remote_id]
			reply = [:already_connected]
		    else
			token, connecting_thread = connection_space.pending_connections[remote_id]
			if token && token < remote_token
			    reply = [:already_connecting]
			else
			    connecting_thread.join if connecting_thread
			    new(connection_space, socket, remote_name, remote_id, remote_state)

			    reply = [:connect, connection_space.name,
				connection_space.remote_id, 
				Distributed.format(Roby::State)]
			end
		    end

		    reply = Marshal.dump(reply)
		    socket.write [reply.size].pack("N")
		    socket.write reply
		end
	    end

	    # Initializes the connection attempt by queueing a 'connected'
	    # message for our remote peer. The peer is supposed to send its
	    # current state back to us, at which point we can assume the
	    # connection is up
	    def connect
		Roby::Distributed.info "connecting to #{remote_name}"
		transmit(:connect, connection_space.name, connection_space.remote_id, Roby::State) do |remote_name, remote_id, remote_state|
		    raise "state is #{@connection_state}, not connecting" unless connecting?

		    connected(remote_name, remote_id, remote_state)
		    Roby::Control.once { task.emit(:ready) }
		    Roby::Distributed.info "connected to #{self}"
		end
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
	    # We will disconnect because of that
	    def fatal_error(error, msg, args)
		synchronize do
		    Roby::Distributed.fatal "fatal error '#{error}' while processing #{msg}(#{args.join(", ")})"
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
		disconnected(:aborted)
	    end

	    # Returns true if we are establishing a connection with this peer
	    def connecting?; connection_state == :connecting end
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
	    
	    def disable_tx; @disabled_tx += 1 end
	    def enable_tx; @disabled_tx -= 1 end
	    def disabled_tx?; @disabled_tx > 0 end
	    def disable_rx; @disabled_rx += 1 end
	    def enable_rx; @disabled_rx -= 1 end
	    def disabled_rx?; @disabled_rx > 0 end

	    # Checks if the connection is currently alive
	    def link_alive?
		return false if @dead || @disabled_rx > 0
		return false unless !remote_id || connection_space.neighbours.find { |n| n.remote_id == remote_id }
		true
	    end

	end

	class PeerServer
	    # Called by our peer to initialize the connection
	    def connect(name, id, state)
		peer.connected(name, id, state)
		[peer.connection_space.name, peer.connection_space.remote_id, Roby::State]
	    end

	    def fatal_error(error, msg, args)
		Distributed.fatal "remote reports #{error} while processing #{msg}(#{args.join(", ")})"
		disconnect
	    end

	    # Called by our peer when it disconnects
	    def disconnect
		peer.disconnected

		nil
	    end
	end

	class RecursiveCallbacksError < RuntimeError; end
	class CallbackProcessingError < RuntimeError; end

	CallSpec = Struct.new :is_callback, 
	    :method, :formatted_args, :original_args,
	    :on_completion, :trace, :waiting_thread

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

	    def synchro_point
		peer.transmit(:done_synchro_point)
		nil
	    end
	    def done_synchro_point; end

	    def completed(result, error)
		call_spec = peer.completion_queue.pop
		if error
		    if call_spec && thread = call_spec.waiting_thread
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
	    #
	    # Since #completed! is destined to be called by other threads than
	    # the communication thread, +comthread+ must be set to the
	    # communication thread object.
	    def completed!(result, error)
		if queued_completion?
		    raise "already queued the completed message"
		else
		    Distributed.debug { "done, returns #{'error ' if error}#{result || 'nil'} in completed!" }
		    self.queued_completion = true
		    peer.queue_call false, :completed, [result, error]
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
		    completed!(error || result, !!error)
		end
	    end
	end

	# == Communication
	# Communication is done in two threads. The sending thread gets the
	# calls from Peer#send_queue, formats them and sends them to the
	# PeerServer#demux for processing. The reception thread is managed by
	# dRb and its entry point is always #demux.
	#
	# Very often we need to have processing on both sides to finish an
	# operation. For instance, the creation of two siblings need to
	# register the siblings on both sides. To manage that, it is possible
	# for PeerServer methods which are serving a remote request to queue
	# callbacks.  These callbacks will be processed by Peer#send_thread
	# before the rest of the queue might be processed
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

	    # Checks that +object+ is marshallable. If +object+ is a
	    # collection, it will check that each of its elements is
	    # marshallable first
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
	    
	    # Add a CallSpec object in #send_queue
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
		    unless call_spec.method == :completed
			completion_queue << call_spec
		    end

		    current_cycle    << [call_spec.is_callback, call_spec.method, call_spec.formatted_args, !waiting_thread]
		    if sync? || CYCLE_END_CALLS.include?(m)
			send_queue << current_cycle
			@current_cycle = Array.new
		    end
		end
	    end

	    # If #transmit calls are done in the block given to #queueing, they
	    # will queue the call instead of marking it as callback
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
	    # Queues a call to the remote host. If a block is given, it is
	    # called in the communication thread, with the returned value, if
	    # the call succeeded
	    def transmit(m, *args, &block)
		is_callback = Roby.inside_control? && local_server.processing?
		if is_callback && local_server.processing_callback?
		    raise RecursiveCallbacksError, "cannot queue callback #{m}(#{args.join(", ")}) while serving one"
		end
		
		Distributed.debug do
		    op = local_server.processing? ? "adding callback" : "queueing"
		    "#{op} #{remote_name}.#{m}"
		end

		queue_call is_callback, m, args, block
	    end

	    # call-seq:
	    #	peer.call(method, arg1, arg2)	    => result
	    #
	    # Calls a method synchronously and returns the value returned by
	    # the remote server. If we disconnect before this call is
	    # processed, raises DisconnectedError. If the remote server returns
	    # an exception, this exception is raised in the thread calling
	    # #call as well.
	    #
	    # Note that it is forbidden to use this method in control or
	    # communication threads, as it would make the application deadlock
	    def call(m, *args)
		if !Roby.outside_control? || Roby::Control.taken_mutex?
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

		loop do
		    data ||= send_queue.shift
		    return if disconnected?

		    # Wait for the link to be alive before sending anything
		    while !link_alive?
			return if disconnected?
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

	    # Calls the block that has been given to #transmit when +call+ is
	    # completed. A remote call is completed when it has been processed
	    # remotely *and* the callbacks returned by the remote server (if
	    # any) have been processed as well. +result+ is the value returned
	    # by the remote server.
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
