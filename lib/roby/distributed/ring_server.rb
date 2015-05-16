require 'rinda/rinda'
require 'rinda/ring'
require 'rinda/tuplespace'

# This file contains extension to dRuby and Rinda classes which are needed to 
# make Distributed Roby work
#
# Some are direct modification of the standard library (through reopening classes),
# others are made by subclassing the standard library.

module Rinda
    class NotifyTemplateEntry
        undef_method :pop
	def pop(nonblock = false)
	    raise RequestExpiredError if @done
	    it = @queue.pop(nonblock) rescue nil
	    @done = true if it && it[0] == 'close'
	    return it
	end
    end
end

module Roby
    module Distributed

    # Reimplements Rinda::RingServer, removing the tuplespace intermediate and
    # the creation of most threads. This is done for performance reasons.
    class RingServer < Rinda::RingServer
	attr_reader :bind, :port

	# Added a :bind option
	def initialize(ts, options = {})
	    options = validate_options options, :bind => Socket.gethostname, :port => Rinda::Ring_PORT

	    @bind = options[:bind]
	    @port = options[:port]

	    @ts  = ts
	    @soc = UDPSocket.new
	    @soc.bind options[:bind], options[:port]
	    @service = service
	end

	def service
	    Thread.new do
		Thread.current.priority = 0
		begin
		    loop do
			msg = @soc.recv(1024)
			tuple, timeout = Marshal.load(msg)
			tuple[1].call(@ts) rescue nil
		    end
		rescue Interrupt
		end
	    end
	end

	def close
	    @service.raise Interrupt, "interrupting RingServer"
	    @soc.close
	end
    end

    end
end

