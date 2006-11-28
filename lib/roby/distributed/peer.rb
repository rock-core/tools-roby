require 'roby/control'
require 'roby/plan'
require 'roby/distributed/proxy'
require 'utilrb/queue'
require 'utilrb/array/to_s'

module Roby
    class Control; include DRbUndumped end
    class Plan; include DRbUndumped end
end

module Roby::Distributed
    class NotAliveError < RuntimeError; end
    class PeerServer
	include DRbUndumped
	attr_reader :peer
	def initialize(peer)
	    @peer = peer 
	end
	
	def demux(calls)
	    calls.each do |obj, args|
		Roby::Distributed.debug { "received #{obj}.#{args} from #{peer}" }
		obj.send(*args)
	    end
	end

	def plan; peer.connection_space.plan end
    end

    class Peer
	# The ConnectionSpace object we act on
	attr_reader :connection_space
	# The local server object for this peer
	attr_reader :local
	# The neighbour we are connected to
	attr_reader :neighbour
	# The last 'keepalive' tuple we wrote on the neighbour's ConnectionSpace
	attr_reader :keepalive

	include MonitorMixin
	attr_reader :send_flushed

	def name; neighbour.name end

	# Listens for new connections on Distributed.state
	def self.connection_listener(connection_space)
	    connection_space.read_all( { 'kind' => :peer, 'tuplespace' => nil, 'remote' => nil } ).each do |entry|
		tuplespace = entry['tuplespace']
		peer = connection_space.peers[tuplespace]

		if peer
		    Roby::Distributed.debug { "Peer #{peer} finalized handshake" }
		    # The peer finalized the handshake
		    peer.connected = true
		elsif neighbour = connection_space.neighbours.find { |n| n.tuplespace == tuplespace }
		    Roby::Distributed.debug { "Peer #{peer} asking for connection" }
		    # New connection attempt from a known neighbour
		    Peer.new(connection_space, neighbour).connected = true
		end
	    end
	end

	# Creates a new peer management object for the remote agent
	# at +tuplespace+
	def initialize(connection_space, neighbour)
	    super() if defined? super

	    @connection_space = connection_space
	    @neighbour	  = neighbour
	    @local        = PeerServer.new(self)
	    @proxies	  = Hash.new
	    @send_queue   = Queue.new
	    @send_flushed = new_cond
	    connection_space.peers[neighbour.tuplespace] = self

	    connect
	end

	def send(*args)
	    @sending = true
	    Roby::Distributed.debug { "queueing #{remote_server}.#{args[0]}" }
	    @send_queue.push([remote_server, args])
	end

	def send_thread
	    @send_thread ||= Thread.new do
		while calls = @send_queue.get
		    break unless connected?
		    while !alive?
			break unless connected?
			connection_space.wait_discovery
		    end

		    # Mux all calls into one array and send them
		    synchronize do
			Roby::Distributed.debug { "sending #{calls.size} commands to #{neighbour.name}" }
			remote_server.demux(calls)
			send_flushed.broadcast
			@sending = false
		    end
		end

		Roby::Distributed.debug "sending thread quit for #{neighbour.name}"
		send_flushed.broadcast
	    end
	end

	def flush
	    synchronize do
		break unless @sending
		send_flushed.wait
	    end
	end

	def connected=(value)
	    @connected = value

	    if value
		send_thread
	    else
		send_queue.push(nil)
		@send_thread.join
		@send_queue.clear
		@send_thread = nil
	    end
	end

	# Writes a connection tuple into the peer tuplespace
	# We consider that two peers are connected when there
	# is this kind of tuple in *both* tuplespaces
	def connect
	    raise "Already connected" if connected?
	    ping
	end

	# Updates our keepalive token on the peer
	def ping(timeout = nil)
	    old, @keepalive = @keepalive, 
		neighbour.tuplespace.write({ 'kind' => :peer, 'tuplespace' => connection_space, 'remote' => @local }, timeout)

	    old.cancel if old
	end

	# Disconnects from the peer
	def disconnect
	    connection_space.peers.delete(neighbour.tuplespace)
	    @connected = false
	    keepalive.cancel if keepalive

	    neighbour.tuplespace.take({ 'kind' => :peer, 'tuplespace' => neighbour.tuplespace, 'remote' => nil }, 0)
	rescue RequestExpiredError
	end

	# Returns true if the connection has been established. See also #alive?
	def connected?; @connected end

	# The server object we use to access the remote plan database
	def remote_server
	    unless alive?
		raise NotAliveError, "connection not currently alive"
	    end
	    return @entry['remote']
	end

	# Checks if the connection is currently alive
	def alive?
	    return false unless connected?
	    return false unless connection_space.neighbours.find { |n| n.tuplespace == neighbour.tuplespace }
	    @entry = connection_space.read({'kind' => :peer, 'tuplespace' => neighbour.tuplespace, 'remote' => nil}, 0) rescue nil
	    return !!@entry
	end

	# Get the remote plan
	def plan; remote_server.plan end

	# Subscribe to a particular remote object
	def subscribe(object)
	end
    end
end

