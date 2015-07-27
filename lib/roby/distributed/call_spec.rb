module Roby
    module Distributed
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
    end
end
