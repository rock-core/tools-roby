module Roby::Distributed
    class PeerServer
	include DRbUndumped
	attr_reader :peer
	def initialize(peer); @peer = peer end
    end

    class Peer
	# The ConnectionSpace object we act on
	attr_reader :connection_space
	# The local server object for this peer
	attr_reader :local
	# The neighbour we are connected to
	attr_reader :neighbour
	# The last 'keepalive' tuple we wrote on neighbour ConnectionSpace
	attr_reader :keepalive

	# Listens for new connections on Distributed.state
	def self.connection_listener(connection_space)
	    connection_space.read_all( { 'kind' => :peer, 'tuplespace' => nil, 'remote' => nil } ).each do |entry|
		tuplespace = entry['tuplespace']
		if peer = connection_space.peers[tuplespace]
		    Roby::Distributed.debug { "Peer #{peer} finalized handshake" }
		    # The peer finalized the handshake
		    peer.connected = true if peer.connected.nil?
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
	    @connection_space = connection_space
	    @neighbour	  = neighbour
	    @local		  ||= PeerServer.new(self)
	    connection_space.peers[neighbour.tuplespace] = self
	    connect
	end

	# Writes a connection tuple into the peer tuplespace
	# We consider that two peers are connected when there
	# is this kind of tuple in *both* tuplespaces
	def connect
	    raise "Already connected" if connected?
	    ping
	end

	attr_accessor :connected

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

	# Checks if the connection is currently alive
	def alive?
	    return false unless connected?
	    return false unless connection_space.neighbours.find { |n| n.tuplespace == neighbour.tuplespace }
	    entry = connection_space.read({'kind' => :peer, 'tuplespace' => neighbour.tuplespace, 'remote' => nil}, 0) rescue nil
	    return !!entry
	end
    end
end

