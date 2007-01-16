module Roby
    module Distributed
	class PeerServer
	    # Called by the remote peer to make us process something. See
	    # #demux_local for the format of +calls+. Returns [result, error]
	    # where +result+ is an array containing the list of returned value
	    # by the N successfull calls, and error is an error raised by call
	    # N+1 (or nil).
	    def demux(calls)
		from = Time.now
		result = []
		demux_local(calls, result)
		Roby.debug "served #{calls.size} calls in #{Time.now - from} seconds"
		[result, nil]

	    rescue Exception => e
		[result, e]
	    end

	    # call-seq:
	    #	demux_local(calls, result = [])		=> result
	    #
	    # Calls the calls in +calls+ in turn and gathers the result in
	    # +result+. +calls+ is an array whose elements are [object,
	    # [method, *args]]. No block is allowed.
	    def demux_local(calls, result = [])
		if !peer.connected?
		    raise DisconnectedError, "#{remote_name} is disconnected"
		end
		calls.each do |obj, args|
		    Roby::Distributed.debug { "processing #{obj}.#{args[0]}(#{args[1..-1].join(", ")})" }
		    Roby::Control.synchronize do
			if args.first == :demux || args.first == :demux_local
			    result << obj.send(:demux_local, args.second, result)
			else
			    result << obj.send(*args)
			end
		    end
		    Roby::Distributed.debug { "done, returns #{result.last}" }
		end

		result
	    end
	end


	class Peer
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

	    # call-seq:
	    #   peer.transmit(method, arg1, arg2, ...) { |ret| ... }
	    #
	    # Queues a call to the remote host. If a block is given, it is called
	    # in the communication thread, with the returned value, if the call
	    # succeeded
	    def transmit(*args, &block)
		if !connected?
		    raise DisconnectedError, "we are not currently connected to #{remote_name}"
		end

		# do some sanity checks
		if !args[0].respond_to?(:to_sym)
		    raise "invalid call #{args}"
		end

		Roby::Distributed.debug { "queueing #{neighbour.name}.#{args[0]}" } #\n  #{caller(4).join("\n  ")})" }
		send_queue.push([[remote_server, args], block, caller])
		@sending = true
	    end

	    # Flushes all commands that are currently queued for this peer.
	    # Returns true if there were commands waiting, false otherwise
	    def flush
		synchronize do
		    return false unless sending?
		    send_flushed.wait
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

			if calls = do_send(calls)
			    error_count += 1 
			    if error_count > self.max_allowed_errors
				Roby::Distributed.fatal do
				    "#{name} disconnecting from #{neighbour.name} because of too much errors"
				end
				disconnect
			    end
			end
		    end
		end

	    rescue Exception
		Roby::Distributed.fatal do
		    "Communication thread dies with\n#{$!.full_message}\nPending calls where:\n  #{calls}"
		end

	    ensure
		send_queue.clear
		synchronize do
		    @sending = nil
		    send_flushed.broadcast
		end
	    end

	    # Formats an error message because +error+ has been reported by +call+
	    def format_error_report(call, error)
		args = call.first.map do |arg|
		    if arg.kind_of?(DRbObject) then arg.inspect
		    else arg.to_s
		    end
		end
			"#{remote_name} reports an error on #{args[0]}.#{args[1]}(#{args[2..-1].join(", ")}):\n#{error.full_message}\ncall was initiated by\n  #{call[2].join("\n  ")}"
	    end

	    # Sends the method call listed in +calls+ to the remote host, calls
	    # the registered callbacks if the call succeeded. If an error
	    # occured, returns the list of calls to be retried. Otherwise,
	    # returns nil
	    def do_send(calls) # :nodoc:
		before_call = Time.now
		Roby::Distributed.debug { "sending #{calls.size} commands to #{neighbour.name}" }
		results, error = begin remote_server.demux(calls.map { |a| a.first })
				 rescue Exception
				     [[], $!]
				 end
		success = results.size
		Roby::Distributed.debug { "#{neighbour.name} processed #{success} commands in #{Time.now - before_call} seconds" }

		# Calls the callbacks registered for the succeeded calls
		(0...success).each do |i|
		    if block = calls[i][1]
			begin
			    block.call(results[i])
			rescue Exception => e
			    Roby.application_error(:droby_callbacks, block, e)
			end
		    end
		end

		if error
		    Roby::Distributed.warn do
			format_error_report(calls[success], error)
		    end

		    case error
		    when DRb::DRbConnError
			Roby::Distributed.warn { "it looks like we cannot talk to #{neighbour.name}" }
			# We have a connection error, mark the connection as not being alive
			link_dead!
		    when DisconnectedError
			Roby::Distributed.warn { "#{neighbour.name} has disconnected" }
			# The remote host has disconnected, do the same on our side
			disconnected!
		    else
			Roby::Distributed.debug { "\n" + error.full_message }
		    end

		    calls[success..-1]
		else
		    calls = nil
		    unless @sending = !send_queue.empty?
			Roby::Distributed.info "sending queue is empty"
			send_flushed.broadcast
		    end
		    nil
		end
	    end

	    def self.flatten_demux_calls(calls)
		flattened = []
		calls.delete_if do |(object, call), block, trace|
		    if call.first == :demux
			args = call.last
			if !args.all? { |_, c| c.first.respond_to?(:to_sym) }
			    raise "invalid call specification #{call} queued by\n  #{trace.join("\n  ")}"
			end
			flattened.concat(flatten_demux_call(call.last, block, trace))
		    end
		end
		calls.concat(flattened)
	    end

	    # Flatten nested calls to demux in +calls+
	    def self.flatten_demux_call(args, block, trace) # :nodoc:
		flattened = []
		args = args.map do |object, call|
		    if call.first == :demux
			flattened.concat(flatten_demux_call(call.last, block, trace))
			nil
		    else
			[[object, call], block, trace]
		    end
		end
		args.compact!
		args.concat(flattened)
	    end
	end
    end
end
