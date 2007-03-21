module Roby
    module Distributed
	class RecursiveCallbacksError < RuntimeError; end
	class CallbackProcessingError < RuntimeError; end

	class CommunicationQueue
	    attr_reader :contents
	    attr_reader :wait_contents
	    attr_reader :mutex
	    def synchronize(&block); mutex.synchronize(&block) end
	    def initialize
		@contents = []
		@mutex    = Mutex.new
		@wait_contents = ConditionVariable.new
	    end
	    def clear; mutex.synchronize { contents.clear }; self end
	    def push(obj)
		mutex.synchronize do
		    contents.push obj
		    wait_contents.signal
		end
	    end
	    def concat(obj)
		mutex.synchronize do
		    contents.concat(obj)
		    wait_contents.signal
		end
		self 
	    end
	    def empty?; mutex.synchronize { contents.empty? } end
	    def get(nonblock = false)
		mutex.synchronize do
		    if contents.empty? && !nonblock
			wait_contents.wait(mutex)
		    end
		    @contents, result = [], @contents
		    return result
		end
	    end
	end

	class PeerServer
	    PROCESSING_CALLBACKS_TLS = 'PEER_SERVER_PROCESSING_CALLBACKS'

	    attribute(:synchro_execute) { ConditionVariable.new }

	    # True if the calls being served has queued callbacks
	    attr_predicate :has_callbacks?, true
	    # True the current thread is processing a remote request
	    def processing?; !processing_callback?.nil? end
	    # True if the current thread is processing a remote request, and if it is a callback
	    def processing_callback?; Thread.current[PROCESSING_CALLBACKS_TLS] end

	    # Called by the remote peer to make us process something. +calls+ elements
	    # are [is_callback, method, args]. Returns [result, error]
	    def demux(calls)
		result = []
		from = Time.now
		if !peer.connected?
		    raise DisconnectedError, "#{remote_name} is disconnected"
		end


		calls.each do |is_callback, method, args|
		    Distributed.debug { "processing #{is_callback ? 'callback' : 'method'} #{method}(#{args.join(", ")})" }
		    Control.synchronize do
			@has_callbacks = false
			Thread.current[PROCESSING_CALLBACKS_TLS] = !!is_callback
			result << send(method, *args)
		    end

		    if has_callbacks?
			peer.transmit(:processed_callbacks)
			return [result, true, nil]
		    end
		    Distributed.debug { "done, returns #{result.last}" }
		end

		[result, false, nil]

	    rescue Exception => e
		if processing_callback?
		    processed_callbacks(e)
		    CallbackProcessingError.exception(e)
		end
		[result, false, e]

	    ensure
		Distributed.debug "served #{result.size} calls in #{Time.now - from} seconds"

		@has_callbacks = false
		Thread.current[PROCESSING_CALLBACKS_TLS] = nil
	    end

	    def synchro_point
		peer.transmit(:done_synchro_point)
		nil
	    end

	    def done_synchro_point; end
	    def processed_callbacks(error = nil)
		result, call_spec = peer.pending_callbacks.pop
		if error
		    if thread = call_spec.last
			thread.raise error
		    else
			Roby.fatal "error while processing callbacks:in #{error.full_message}"
		    end

		else
		    peer.call_attached_block(call_spec, result)
		end
		nil
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

		result = nil
		Roby::Control.once do
		    result = yield
		    synchro_execute.broadcast
		end
		synchro_execute.wait(Control.mutex)
		result
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
	    attr_reader :mutex
	    def synchronize; @mutex.synchronize { yield } end
	    attr_reader :send_flushed
	    attr_reader :send_thread
	    attribute(:pending_callbacks) { Queue.new }

	    # A list of ConditionVariable object that can be used by #call and #synchro_point
	    attr_reader :condition_variables

	    def get_condvar
		if condition_variables.empty?
		    ConditionVariable.new
		else
		    condition_variables.shift
		end
	    end
	    def return_condvar(condvar)
		condition_variables.unshift(condvar)
	    end

	    # True if we are currently something. Note that sending? is true when 
	    # #do_send is sending something to the remote host, so it is possible to
	    # have #sending? return true while send_queue is empty.
	    def sending?; @sending end

	    # The queue which holds all calls to the remote peer. An element of the queue
	    # is [[object, [method, args]], callback, trace], where
	    # * +object+ is the remote object on which method(args) is to be called
	    # * +callback+ is a proc object which will be called when the method has
	    #   successfully been called on the remote object, with the returned value
	    #   as argument$
	    # * trace is the location (as returned by Kernel#caller) from which the call
	    #   has been queued. It is mainly used for debugging purposes
	    attr_reader :send_queue

	    def check_marshallable(object)
		if object.respond_to?(:each)
		    object.each do |obj|
			begin
			    check_marshallable(obj)
			rescue Exception
			    Roby.fatal "cannot dump #{obj}"
			end
		    end
		end
		Marshal.dump(object)
	    end
	    
	    def queue_call(is_callback, m, args = [], block = nil, thread = nil)
		if !connected?
		    raise DisconnectedError, "we are not currently connected to #{remote_name}"
		end

		# do some sanity checks
		if !m.respond_to?(:to_sym)
		    raise ArgumentError, "method argument should be a symbol, was #{m.class}"
		elsif m.to_sym == :demux
		    raise ArgumentError, "you cannot queue a demux call"
		end

		# Marshal DRoby-dumped objects now, since the object may be
		# modified between now and the time it is sent
		args = Distributed.format(args, self)

		if Roby::Distributed::DEBUG_MARSHALLING
		    check_marshallable(args)
		end
		
		send_queue.push [is_callback, m, args, block, caller(2), thread]
		@sending = true
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
			raise RecursiveCallbacksError, "cannot queue a callback while serving one"
		    end
		    local.has_callbacks = true
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
	    def call(m, *args)
		if local.processing?
		    raise "currently processing a remote request. Use #callback instead"
		elsif Thread.current == Roby.control.thread
		    raise "in control thread"
		end

		result = nil
		synchronize do
		    synchro_call = get_condvar
		    Distributed.debug do
			"calling #{neighbour.name}.#{m}"
		    end

		    queue_call false, m, args, Proc.new { |result| synchro_call.broadcast }, Thread.current
		    synchro_call.wait(mutex)
		    return_condvar synchro_call
		end

		result
	    end

	    # Flushes all commands that are currently queued for this peer.
	    # Returns true if there were commands waiting, false otherwise
	    def flush
		synchronize do
		    return false unless sending?
		    send_flushed.wait(mutex)

		    if !connected?
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
		while calls ||= send_queue.get
		    return unless connected?
		    # Wait for the link to be alive before sending anything
		    while !link_alive?
			return unless connected?
			connection_space.wait_discovery
		    end

		    # Mux all pending calls into one array and send them
		    synchronize do
			return unless connected?
			calls.concat(send_queue.get(true))

			error, calls = do_send(calls)
			if error
			    @failing_error = error
			    Distributed.fatal "#{name} disconnecting from #{neighbour.name} because of error"

			    # Check that there is no thread waiting for the call to
			    # finish. If it is the case, raise the exception in
			    # that thread as well
			    if calls && thread = calls.first.last
				thread.raise error
				calls.shift
			    end

			    disconnected!
			    return
			end

			if !calls || calls.empty?
			    calls = nil
			    unless @sending = !send_queue.empty?
				Distributed.debug "sending queue is empty"
				send_flushed.broadcast
			    end
			end
		    end
		end

	    rescue Exception
		Distributed.fatal do
		    "Communication thread dies with\n#{$!.full_message}\nPending calls where:\n  #{calls}"
		end

	    ensure
		Distributed.info "communication thread quit for #{self}"
		synchronize do
		    disconnected!
		    @sending = nil
		    calls ||= []
		    calls.concat send_queue.get(true)
		    while !pending_callbacks.empty?
			calls << pending_callbacks.pop.last
		    end
		    calls.each do |call_spec|
			next unless call_spec
			if thread = call_spec.last
			    thread.raise DisconnectedError
			end
		    end
		    send_flushed.broadcast
		end
	    end

	    # Formats the RPC specification +call+ in a string suitable for debugging display
	    def call_to_s(call)
		return "" unless call

		args = call[2].map do |arg|
		    if arg.kind_of?(DRbObject) then arg.inspect
		    else arg.to_s
		    end
		end
		"#{call[1]}(#{args.join(", ")})"
	    end
	    # Formats an error message because +error+ has been reported by +call+
	    def report_remote_error(call, error)
		if call
		    "#{remote_name} reports an error on #{call_to_s(call)}:\n#{error.full_message}\n" +
		    "call was initiated by\n  #{call[4].join("\n  ")}"
		else
		    "#{remote_name} reports an error on:\n#{error.full_message}"
		end
	    end

	    # Calls the block that has been given to #transmit when +call+ is
	    # finalized. A remote call is finalized when it has been processed
	    # remotely *and* the callbacks returned by the remote server (if
	    # any) have been processed as well. +result+ is the value returned
	    # by the remote server.
	    def call_attached_block(call, result)
		if block = call[3]
		    begin
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
	    # Returns [error, remaining_calls], where +error+ is true if an
	    # error occured, and +remaining_calls+ is the list of calls to be
	    # retried.
	    def do_send(calls) # :nodoc:
		before_call = Time.now
		Distributed.debug { "sending #{calls.size} commands to #{neighbour.name}" }
		results, has_callbacks, error = begin remote_server.demux(calls.map { |a| a[0, 3] })
				 rescue Exception
				     [[], false, $!]
				 end

		remaining_calls = calls[results.size..-1]
		if has_callbacks
		    result    = results.pop
		    call_spec = calls[results.size]
		    pending_callbacks << [result, call_spec]
		end

		success = results.size
		Distributed.debug do
		    "#{neighbour.name} processed #{success} commands in #{Time.now - before_call} seconds"
		end
		(0...success).each { |i| call_attached_block(calls[i], results[i]) }

		if error
		    case error
		    when DRb::DRbConnError
			Distributed.warn { "it looks like we cannot talk to #{neighbour.name}" }
			# We have a connection error, mark the connection as not being alive
			link_dead!
		    when DisconnectedError
			Distributed.warn { "#{neighbour.name} has disconnected" }
			# The remote host has disconnected, do the same on our side
			disconnected!
		    else
			Distributed.warn do
			    report_remote_error(remaining_calls.first, error)
			end
		    end
		end
		[error, remaining_calls]
	    end

	    def synchro_point; call(:synchro_point) end
	end
    end
end
