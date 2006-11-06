# :file:drb.rb
#
# This file contains extension to DRuby and Rinda classes which are needed to 
# make Distributed Roby work
#
# Some are direct modification of the standard library (through reopening classes),
# others are made by subclassing the standard library.

module Rinda
    class NotifyTemplateEntry
	def pop(nonblock = false)
	    raise RequestExpiredError if @done
	    it = @queue.pop(nonblock) rescue nil
	    @done = true if it && it[0] == 'close'
	    return it
	end
    end
end

module Roby::Distributed
    # Reimplements Rinda::RingServer, removing the tuplespace intermediate and
    # the creation of most threads. This is done for performance reasons.
    class RingServer < Rinda::RingServer
	# Added a :bind option
	def initialize(ts, options = {})
	    options = validate_options options, :bind => '', :port => Rinda::Ring_PORT
	    @ts  = ts
	    @soc = UDPSocket.new
	    @soc.bind options[:bind], options[:port]
	    @w_service = write_service
	end

	def do_write(msg)
	    tuple, timeout = Marshal.load(msg)
	    tuple[1].call(@ts) rescue nil
	rescue
	end
    end
end

