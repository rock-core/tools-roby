module Roby
    module Distributed
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

	    # Converts this object to what PeerServer#demux expects
	    def to_demux_argument; [is_callback, method, formatted_args] end

	    def to_s
		args = formatted_args.map do |arg|
		    if arg.kind_of?(DRbObject) then arg.inspect
		    else arg.to_s
		    end
		end
		"#{method}(#{args.join(", ")})"
	    end
	end

	# A multi-threaded FIFO
	class CommunicationQueue
	    # The elements inside the queue, as an Array
	    attr_reader :contents
	    # The synchronization mutex for this queue
	    attr_reader :mutex
	    # A ConditionVariable which is signalled when the queue is empty
	    attr_reader :wait_clear
	    # A ConditionVariable which is signalled when there is contents in the queue
	    attr_reader :wait_contents
	    # If not nil, specifies a maximum size for the queue: if there is
	    # more than #max_size elements waiting in the queue, #push and
	    # #concat will block, waiting for the queue to be empty
	    attr_reader :max_size

	    def synchronize(&block); mutex.synchronize(&block) end

	    def initialize(max_size = nil)
		@contents = []
		@mutex    = Mutex.new
		@wait_contents = ConditionVariable.new
		@wait_clear = ConditionVariable.new
		@max_size = max_size
	    end

	    # This method will wait for #wait_clear if there is a limit on the
	    # queue size, and if there is not enough room left
	    #
	    # It must be called with #mutex locked
	    def check_room
		if max_size && contents.size >= max_size
		    wait_clear.wait(mutex)
		end
	    end

	    # Add a new element at the end of the queue
	    def push(obj)
		mutex.synchronize do
		    check_room
		    contents.push obj
		    wait_contents.broadcast
		end
	    end

	    # Add a set of elements at the end of the queue
	    def concat(obj)
		mutex.synchronize do
		    check_room
		    contents.concat(obj)
		    wait_contents.broadcast
		end
		self 
	    end

	    # Removes the first element from the queue
	    def pop
		mutex.synchronize do
		    element = contents.shift
		    if contents.empty?
			# Hack to fix the shift/push bug on arrays
			@contents = []
			wait_clear.broadcast
		    end
		    element
		end
	    end

	    # True if the queue is empty
	    def empty?; mutex.synchronize { contents.empty? } end
	    # How many elements are there in the queue now ?
	    def size; mutex.synchronize { contents.size } end

	    # Get all elements at once. If +nonblock+ is true and if there is
	    # no elements in the queue, returns an empty array. If +nonblock+
	    # is false, waits for new elements
	    def get(nonblock = false)
		mutex.synchronize do
		    if contents.empty? && !nonblock
			wait_contents.wait(mutex)
		    end
		    @contents, result = [], @contents
		    wait_clear.broadcast
		    return result
		end
	    end

	    # Removes all elements from the queue
	    def clear
	       	mutex.synchronize do 
		    contents.clear 
		    wait_clear.broadcast
		end 
		self 
	    end
	end

	class PeerServer
	    PROCESSING_CALLBACKS_TLS = 'PEER_SERVER_PROCESSING_CALLBACKS'
	    QUEUED_COMPLETION_TLS    = 'PEER_SERVER_QUEUED_COMPLETION'

	    # True the current thread is processing a remote request
	    def processing?; !processing_callback?.nil? end
	    # True if the current thread is processing a remote request, and if it is a callback
	    def processing_callback?; Thread.current[PROCESSING_CALLBACKS_TLS] end
	    # True if we have already queued a +completed+ message for the message being processed
	    def queued_completion?; Thread.current[QUEUED_COMPLETION_TLS] end

	    # Called by the remote peer to make us process something. +calls+ elements
	    # are [is_callback, method, args]. Returns [result, error]
	    def demux(calls)
		from = Time.now
		calls_size = calls.size

		if peer.disconnected?
		    raise DisconnectedError, "not connected to #{remote_name}"
		end

		while call_spec = calls.shift
		    return unless call_spec

		    is_callback, method, args = *call_spec
		    Distributed.debug do 
			args_s = args.map { |obj| obj ? obj.to_s : 'nil' }
			"processing #{is_callback ? 'callback' : 'method'} #{method}(#{args_s.join(", ")})"
		    end

		    result = Control.synchronize do
			Thread.current[QUEUED_COMPLETION_TLS] = false
			Thread.current[PROCESSING_CALLBACKS_TLS] = !!is_callback
			send(method, *args)
		    end

		    if method != :completed && method != :disconnected
			if queued_completion?
			    Distributed.debug "done, already queued the completion message"
			else
			    Distributed.debug { "done, returns #{result || 'nil'}" }
			    peer.queue_call false, :completed, [result, false]
			end
		    end
		end

		Distributed.debug "successfully served #{calls_size} calls in #{Time.now - from} seconds"
		nil

	    rescue Exception => e
		if processing_callback?
		    completed(e, true)
		    e = CallbackProcessingError.exception(e)
		end
		[calls_size - calls.size - 1, e]

	    ensure
		Thread.current[PROCESSING_CALLBACKS_TLS] = nil
	    end

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
			Roby.fatal "error while processing callbacks:in #{result.full_message}"
		    end

		elsif call_spec
		    peer.call_attached_block(call_spec, result)
		end

		if !peer.sending?
		    peer.synchronize do
			if !peer.sending?
			    Distributed.debug "sending queue is empty"
			    peer.send_flushed.broadcast
			end
		    end
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
		    Thread.current[QUEUED_COMPLETION_TLS] = true
		    queue_call false, :completed, [result, false]
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
		    begin
			completed!(yield, false)
		    rescue Exception => error
			completed!(error, true)
		    end
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
	    # The main synchronization mutex to access the peer.
	    # See also Peer#synchronize
	    attr_reader :mutex
	    def synchronize; @mutex.synchronize { yield } end

	    # The transmission thread
	    attr_reader :send_thread

	    # The queue which holds all calls to the remote peer. Calls are 
	    # saved as CallSpec objects
	    attr_reader :send_queue
	    # A condition variable announcing that all messages in send_queue
	    # has been sent
	    attr_reader :send_flushed 
	    # The queue of calls that have been sent to our peer, but for which
	    # a +completed+ message has not been received. This is a queue
	    # of CallSpec objects
	    attr_reader :completion_queue

	    # True if we are currently something. Note that sending? is true
	    # when #do_send is sending something to the remote host, so it is
	    # possible to have #sending? return true while send_queue and/or
	    # completion_queue are empty.
	    def sending?
	       	(@sending || !send_queue.empty? || !completion_queue.empty?) && !disconnected?
	    end

	    def check_marshallable(object, stack = ValueSet.new)
		if !object.kind_of?(DRbObject) && object.respond_to?(:each) && !object.kind_of?(String)
		    if stack.include?(object)
			Roby.warn "recursive marshalling of #{obj}"
			raise "recursive marshalling"
		    end

		    stack << object
		    begin
			object.each do |obj|
			    begin
				check_marshallable(obj, stack)
			    rescue Exception
				Roby.warn "cannot dump #{obj}(#{obj.class}): #{$!.message}"
				raise
			    end
			end
		    ensure
			stack.delete(object)
		    end
		end
		Marshal.dump(object)
	    end
	    
	    # Add a CallSpec object in #send_queue
	    def queue_call(is_callback, m, args = [], on_completion = nil, waiting_thread = nil)
		# Do some sanity checks
		if !m.respond_to?(:to_sym)
		    raise ArgumentError, "method argument should be a symbol, was #{m.class}"
		elsif m.to_sym == :demux
		    raise ArgumentError, "you cannot queue a demux call"
		end

		# Check the connection state
		if connecting?
		    if m != :connect && m != :connected
			raise DisconnectedError, "cannot queue #{m}(#{args.join(", ")}) while we are connecting"
		    end
		elsif disconnecting?
		    if m != :disconnected && m != :completed
			raise DisconnectedError, "cannot queue #{m}(#{args.join(", ")}) while we are disconnecting"
		    end
		elsif disconnected?
		    raise DisconnectedError, "cannot queue #{m}(#{args.join(", ")}), we are not currently connected to #{remote_name}"
		end

		# Marshal DRoby-dumped objects now, since the object may be
		# modified between now and the time it is sent
		formatted_args = Distributed.format(args, self)

		if Roby::Distributed::DEBUG_MARSHALLING
		    check_marshallable(args)
		end
		
		@sending = true
		call_spec = CallSpec.new(is_callback, 
			    m, formatted_args, args, 
			    on_completion, caller(2), waiting_thread)

		if m == :state_update
		    Roby.debug "merged the state_update call with the previous one"
		    send_queue.synchronize do
			if !send_queue.contents.empty? && send_queue.contents[-1].method == :state_update
			    send_queue.contents[-1].formatted_args = formatted_args
			else
			    send_queue.contents.push call_spec
			    send_queue.wait_contents.broadcast
			end
		    end
		else
		    send_queue.push call_spec
		end

	    end

	    # call-seq:
	    #   peer.transmit(method, arg1, arg2, ...) { |ret| ... }
	    #
	    # Queues a call to the remote host. If a block is given, it is called
	    # in the communication thread, with the returned value, if the call
	    # succeeded
	    def transmit(m, *args, &block)
		if local.processing?
		    if local.processing_callback?
			raise RecursiveCallbacksError, "cannot queue callback #{m}(#{args.join(", ")}) while serving one"
		    end
		end
		
		Distributed.debug do
		    op = local.processing? ? "adding callback" : "queueing"
		    "#{op} #{neighbour.name}.#{m}"
		end

		queue_call local.processing?, m, args, block
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
		if local.processing?
		    raise "cannot use Peer#call while processing a remote request"
		elsif Roby.inside_control?
		    raise "cannot use Peer#call in control thread"
		end

		result = nil
		Roby.condition_variable(true) do |cv, mt|
		    mt.synchronize do
			Distributed.debug do
			    "calling #{neighbour.name}.#{m}"
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

	    # Flushes all commands that are currently queued for this peer.
	    # Returns true if there were commands waiting, false otherwise
	    def flush
		synchronize do
		    return false unless sending?

		    Distributed.debug "flushing ..."
		    send_flushed.wait(mutex)

		    if disconnected?
			if @failing_error
			    raise @failing_error
			else
			    raise DisconnectedError, "disconnected from our peer"
			end
		    end
		end
		true
	    end
	    
	    # Main loop of the thread which communicates with the remote peer
	    def communication_loop
		Thread.current.priority = 2
		loop do
		    calls = send_queue.get
		    return if disconnected?
		    # Wait for the link to be alive before sending anything
		    while !link_alive?
			return if disconnected?
			connection_space.wait_next_discovery
		    end

		    # Mux all pending calls into one array and send them
		    return if disconnected?
		    calls.concat(send_queue.get(true))

		    error_call, error = do_send(calls)
		    synchronize do
			if error
			    @failing_error = error
			    Distributed.warn "#{name} disconnecting from #{neighbour.name} because of error"

			    # Check that there is no thread waiting for the call to
			    # finish. If it is the case, raise the exception in
			    # that thread as well
			    if error_call && thread = error_call.waiting_thread
				thread.raise error
			    end

			    disconnected!
			    return
			end

			@sending = !send_queue.empty?
			if !sending?
			    Distributed.debug "sending queue is empty"
			    send_flushed.broadcast
			end
		    end
		end

	    rescue Interrupt
	    rescue Exception
		Distributed.fatal do
		    "Communication thread dies with\n#{$!.full_message}" #Pending calls where:\n  #{calls}"
		end

		synchronize do
		    disconnected!
		end

	    ensure
		Distributed.info "communication thread quitting for #{self}"
		calls = completion_queue.get(true)
		calls.concat send_queue.get(true)
		calls.each do |call_spec|
		    next unless call_spec
		    if thread = call_spec.waiting_thread
			thread.raise DisconnectedError
		    end
		end

		Distributed.info "communication thread quit for #{self}"

		synchronize do
		    @sending = nil
		    send_flushed.broadcast
		end
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
			Roby.debug "calling completion block #{block} for #{call}"
			block.call(result)
		    rescue Exception => e
			Roby.application_error(:droby_callbacks, block, e)
		    end
		end
	    end

	    # Sends the method call listed in +calls+ to the remote host, and
	    # calls the attached blocks with the value returned by the remote
	    # server if the call succeeds. 
	    #
	    # Returns an error if an error occured, or nil
	    def do_send(calls) # :nodoc:
		before_call = Time.now
		Distributed.debug { "sending #{calls.size} commands to #{neighbour.name}" }
		completion_queue.concat calls.find_all { |c| c.method != :completed && c.method != :disconnected }
		error_call, error = begin remote_server.demux(calls.map { |a| a.to_demux_argument })
				    rescue Exception => error
					[0, error]
				    end

		case error
		when DRb::DRbConnError
		    if error.message =~ /ECONNREFUSED/
			Distributed.warn "#{remote_name} is no more ..."
		    else
			Distributed.warn "it looks like we cannot talk to #{neighbour.name} (#{error.message})"
			# We have a connection error, mark the connection as not being alive
			link_dead!
			error = nil
		    end
		when DisconnectedError
		    Distributed.debug do
			report_remote_error(calls[error_call], error)
		    end
		    Distributed.warn "#{neighbour.name} has disconnected"
		when Exception
		    Distributed.warn do
			report_remote_error(calls[error_call], error)
		    end 
		else
		    Distributed.debug do
			"#{neighbour.name} processed #{calls.size} commands in #{Time.now - before_call} seconds"
		    end
		end
		if error
		    [calls[error_call], error]
		end
	    end

	    def synchro_point; call(:synchro_point) end
	end
    end
end
