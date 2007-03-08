module Roby
    module Distributed
	class PeerServer
	    attribute(:synchro_execute) { ConditionVariable.new }

	    CALLBACKS_TLS = :peer_server_callbacks
	    def callbacks; Thread.current[CALLBACKS_TLS] end
	    def processing?; !!callbacks end

	    # Called by the remote peer to make us process something. See
	    # #demux_local for the format of +calls+. Returns [result, callbacks, error]
	    # where +result+ is an array containing the list of returned value
	    # by the N successfull calls. Error, if not nil, is an error raised
	    # by call N+1. Callbacks is a set of commands to be sent do #demux_local
	    # on the other side, to finalize the N+1th call.
	    def demux(calls)
		result = []
		if !peer.connected?
		    raise DisconnectedError, "#{remote_name} is disconnected"
		end

		from = Time.now

		Thread.current[CALLBACKS_TLS] = []
		demux_local(calls, result)

		Distributed.debug "served #{calls.size} calls in #{Time.now - from} seconds, #{callbacks.size} callbacks"
		[result, callbacks, nil]

	    rescue Exception => e
		[result, nil, e]

	    ensure
		Thread.current[CALLBACKS_TLS] = nil
	    end

	    def demux_local(calls, result)
		calls.each do |args|
		    Distributed.debug { "processing #{args[0]}(#{args[1..-1].join(", ")})" }
		    if args.first == :demux || args.first == :demux_local
			demux_local(args[1], result)
		    else
			Control.synchronize do
			    result << send(*args)
			end
		    end
		    return true unless callbacks.empty?
		    Distributed.debug { "done, returns #{result.last}" }
		end
	    end
	    private :demux_local

	    def synchro_point
		peer.queue_call(:done_synchro_point)
		nil
	    end

	    def done_synchro_point
		peer.synchro_point_mutex.synchronize do
		    peer.synchro_point_done.broadcast
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


	class Peer
	    attr_reader :mutex
	    def synchronize; @mutex.synchronize { yield } end
	    attr_reader :send_flushed
	    attr_reader :synchro_call

	    # Mutex use by #synchro_point
	    attr_reader :synchro_point_mutex
	    # Condition variable use by #synchro_point
	    attr_reader :synchro_point_done

	    # How many errors we accept before disconnecting
	    attr_reader :max_allowed_errors

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
	    
	    def format_remote_call(m, args, block)
		if !connected?
		    raise DisconnectedError, "we are not currently connected to #{remote_name}"
		end

		# do some sanity checks
		if !m.respond_to?(:to_sym)
		    raise "invalid call #{args}"
		end

		# Marshal DRoby-dumped objects now, since the object may be
		# modified between now and the time it is sent
		args.map! { |obj| Distributed.format(obj) }
		args.unshift m

		[args, block, caller(2)]
	    end

	    # call-seq:
	    #   peer.callback(method, arg1, arg2, ...) { |ret| ... }
	    #
	    # Queues a callback to be processed by the remote host. Callbacks
	    # are processed in return of a remote procedure call, so this
	    # method must be called when answering a call from the remote host.
	    # Callbacks are processed by the remote server before any call it
	    # has already queued.	
	    def callback(m, *args)
		if !local.processing?
		    raise "not processing a remote request. Use #transmit in normal context"
		end
		if block_given?
		    raise "no block allowed in callbacks"
		end

		Distributed.debug do
		    "adding callback #{neighbour.name}.#{m}" 
		    # from\n  #{caller(5)[0, 5].join("\n  ")}" } #\n  #{caller(4).join("\n  ")})"
		end
		local.callbacks << format_remote_call(m, args, nil)
	    end

	    def queue_call(m, *args, &block)
		Distributed.debug do
		    "queueing #{neighbour.name}.#{m}"
		    # from\n  #{caller(5)[0, 5].join("\n  ")}" } #\n  #{caller(4).join("\n  ")})"
		end
		send_queue.push(format_remote_call(m, args, block))
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
		    if block_given?
			# We are queueing this call as a callback. Act as if
			# it was already processed and call the block
			yield
		    end
		    callback(m, *args)
		else
		    queue_call(m, *args, &block)
		end
	    end

	    # call-seq:
	    #	peer.call(method, arg1, arg2)	    => result
	    def call(m, *args)
		if local.processing?
		    raise "currently processing a remote request. Use #callback instead"
		elsif Thread.current == Roby.control.thread
		    raise "in control thread"
		end

		result = nil
		synchronize do
		    transmit(m, *args) do |result|
			synchro_call.broadcast
		    end
		    synchro_call.wait(mutex)
		end

		result
	    end

	    # Flushes all commands that are currently queued for this peer.
	    # Returns true if there were commands waiting, false otherwise
	    def flush
		synchronize do
		    return false unless sending?
		    send_flushed.wait(mutex)

		    if !@send_thread
			raise "communication thread died"
		    end
		end
		true
	    end
	    
	    # Main loop of the thread which communicates with the remote peer
	    def communication_loop
		error_count = 0
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
			calls = Peer.flatten_demux_calls(calls)

			error, calls = do_send(calls)
			if error
			    error_count += 1 
			    if error_count > self.max_allowed_errors
				Distributed.fatal do
				    "#{name} disconnecting from #{neighbour.name} because of too much errors"
				end
				disconnected!
			    end
			end

			if !calls || calls.empty?
			    calls = nil
			    unless @sending = !send_queue.empty?
				Distributed.info "sending queue is empty"
				send_flushed.broadcast
			    end
			    nil
			end
		    end
		end

	    rescue Exception
		Distributed.fatal do
		    "Communication thread dies with\n#{$!.full_message}\nPending calls where:\n  #{calls}"
		end

	    ensure
		synchronize do
		    disconnected!
		    @sending = nil
		    send_queue.clear
		    send_flushed.broadcast
		end
	    end

	    # Formats the RPC specification +call+ in a string suitable for debugging display
	    def call_to_s(call)
		return "" unless call

		args = call.first.map do |arg|
		    if arg.kind_of?(DRbObject) then arg.inspect
		    else arg.to_s
		    end
		end
		"#{args[0]}(#{args[1..-1].join(", ")})"
	    end
	    # Formats an error message because +error+ has been reported by +call+
	    def report_remote_error(call, error)
		"#{remote_name} reports an error on #{call_to_s(call)}:\n#{error.full_message}\n" +
		"call was initiated by\n  #{call[2].join("\n  ")}"
	    end
	    def report_callback_error(callback, remote_call, error)
		"error while calling callback #{call_to_s(callback)}:\n#{error.full_message}\n" +
		"original call was\n  #{call_to_s(remote_call)}"
	    end
	    def report_nested_callbacks(callbacks, local_call, remote_call)
		callbacks = callbacks.map { |c| call_to_s(c) }
		"nested callbacks: #{callbacks.join("\n  ")}\n" +
		"have been queued by #{call_to_s(local_call)}\n" +
		"original call was #{call_to_s(remote_call)}"
	    end

	    # Calls the block that has been given to #transmit when +call+ is
	    # finalized. A remote call is finalized when it has been processed
	    # remotely *and* the callbacks returned by the remote server (if
	    # any) have been processed as well. +result+ is the value returned
	    # by the remote server.
	    def call_attached_block(call, result)
		if block = call[1]
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
		results, callbacks, error = begin remote_server.demux(calls.map { |a| a.first })
					    rescue Exception
						[[], nil, $!]
					    end
		success = results.size
		Distributed.debug do
		    "#{neighbour.name} processed #{success} commands in #{Time.now - before_call} seconds"
		end

		# Calls the user-provided blocks. If there are callbacks, they
		# must be processed first
		success -= 1 if callbacks && !callbacks.empty?
		(0...success).each { |i| call_attached_block(calls[i], results[i]) }
		
		if error
		    Distributed.warn do
			report_remote_error(calls[success], error)
		    end

		    case error
		    when DRb::DRbConnError
			Distributed.warn { "it looks like we cannot talk to #{neighbour.name}" }
			# We have a connection error, mark the connection as not being alive
			link_dead!
		    when DisconnectedError
			Distributed.warn { "#{neighbour.name} has disconnected" }
			# The remote host has disconnected, do the same on our side
			disconnected!
			return [true, nil]
		    end
		    [true, calls[success..-1]]

		elsif !callbacks.empty?
		    new_results, new_calls, error = local.demux(callbacks.map { |c| c.first })
		    if new_calls && !new_calls.empty?
			Distributed.warn do
			    report_nested_callbacks(new_calls, callbacks[new_results.size - 1], calls[success])
			end
			Roby.application_error :droby_nested_remote_callbacks, 
			    callbacks[new_results.size - 1], 
			    RuntimeError.exception("nested callbacks")
			[false, calls[(success + 1)..-1]]
		    elsif error 
			if error.kind_of?(DisconnectedError)
			    return [true, nil]
			end

			Distributed.warn do
			    report_callback_error(callbacks[new_results.size], calls[success], error)
			end
			Roby.application_error :droby_remote_callback, 
			    callbacks[new_results.size], error
			[true, calls[success..-1]]
		    else
			call_attached_block(calls[success], results[success])
			[false, calls[(success + 1)..-1]]
		    end

		end
	    end

	    def synchro_point(&block)
		synchro_point_mutex.synchronize do
		    queue_call(:synchro_point)
		    synchro_point_done.wait(synchro_point_mutex)
		end
	    end

	    def self.flatten_demux_calls(calls)
		flattened = []
		calls.delete_if do |call, block, trace|
		    if call.first == :demux
			args = call.last
			if !args.all? { |c| c.first.respond_to?(:to_sym) }
			    raise "invalid call specification #{call} queued by\n  #{trace.join("\n  ")}"
			end
			flattened.concat(flatten_demux_call(args, block, trace))
		    end
		end
		calls.concat(flattened)
	    end

	    # Flatten nested calls to demux in +calls+
	    def self.flatten_demux_call(args, block, trace) # :nodoc:
		flattened = []
		args = args.map do |call|
		    if call.first == :demux
			flattened.concat(flatten_demux_call(call.last, block, trace))
			nil
		    else
			[call, block, trace]
		    end
		end
		args.compact!
		args.concat(flattened)
	    end
	end
    end
end
