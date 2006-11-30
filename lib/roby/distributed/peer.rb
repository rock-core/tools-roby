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
	attr_reader :subscriptions

	def initialize(peer)
	    @peer	    = peer 
	    @subscriptions  = ValueSet.new
	end

	def client_name; peer.connection_space.name end
	def server_name; peer.neighbour.name end
	
	def demux(calls)
	    idx = 0
	    calls.each do |obj, args|
		Roby::Distributed.debug { "processing #{obj}.#{args[0]}(#{args[1..-1].join(", ")})" }
		obj.send(*args)
		idx += 1
	    end

	    [idx, nil]

	rescue
	    [idx, $!]
	end

	def plan; peer.connection_space.plan end
	def discover_neighborhood(object, distance)
	    edges = object.neighborhood(distance)
	    if object.kind_of?(Roby::Task)
		object.each_event do |obj_ev|
		    edges += obj_ev.neighborhood(distance)
		end
	    end

	    # Replace the relation graphs by their name
	    edges.map! do |rel, from, to, info|
		[peer.remote_server, [:update_relation, [from, :add_child_object, to, rel, info]]]
	    end
	    peer.send(:demux, edges)
	    nil
	end

	def subscribe(object)
	    return if subscribed?(object)

	    unless object.kind_of?(Roby::Task) || object.kind_of?(Roby::EventGenerator)
		raise TypeError, "cannot subscribe a #{object.class} object"
	    end
	    subscriptions << object
	    send_subscribed_relations(object)

	    if object.respond_to?(:each_event)
		object.each_event(false, &method(:subscribe))
	    end
	    nil
	end
	def subscribed?(object); subscriptions.include?(object) end

	def send_subscribed_relations(object)
	    result = []
	    object.each_graph do |graph|
		graph_edges = []
		object.each_child_object(graph) do |child|
		    if subscribed?(child)
			graph_edges << [object, child, object[child, graph]]
		    end
		end
		object.each_parent_object(graph) do |parent|
		    if subscribed?(parent)
			graph_edges << [parent, object, parent[object, graph]]
		    end
		end
		result << [graph, graph_edges]
	    end

	    # Send event if +result+ is empty, so that relations are
	    # removed if needed on the other side
	    peer.send(:set_relations, object, result)
	end

	def unsubscribe(object)
	    subscriptions.delete(object)
	    if object.respond_to?(:each_event)
		object.each_event(&method(:unsubscribe))
	    end
	    nil
	end

	def apply(args)
	    args.map! do |a|
		if peer.proxying?(a)
		    peer.proxy(a)
		else a
		end
	    end

	    yield(args)
	end

	# Receive the list of relations of +object+. The relations are given in
	# an array like [[graph, from, to, info], [...], ...]
	def set_relations(object, relations)
	    parents  = Hash.new { |h, k| h[k] = Array.new }
	    children = Hash.new { |h, k| h[k] = Array.new }

	    object = peer.proxy(object)
	    
	    # Add or update existing relations
	    relations.each do |graph, graph_relations|
		graph_relations.each do |args|
		    apply(args) do |from, to, info|
			if to == object
			    parents[graph]  << from
			elsif from == object
			    children[graph] << to
			else
			    raise ArgumentError, "trying to set a relation #{from} -> #{to} in which self(#{object}) in neither parent nor child"
			end

			if graph.linked?(from, to)
			    from[to, graph] = info
			else
			    Roby::Distributed.update(from, to) do
				from.add_child_object(to, graph, info)
			    end
			end
		    end
		end
	    end

	    object.each_relation do |rel|
		# Remove relations that do not exist anymore
		(object.parent_objects(rel) - parents[rel]).each do |p|
		    if p.owners == [peer]
			Roby::Distributed.update(p, object) do
			    p.remove_child_object(object, rel)
			end
		    end
		end
		(object.child_objects(rel) - children[rel]).each do |c|
		    if c.owners == [peer]
			Roby::Distributed.update(c, object) do
			    object.remove_child_object(c, rel)
			end
		    end
		end
	    end

	    nil
	end

	# Receive an update on the relation graphs
	#  object:: the object being updated
	#  action:: a list of actions to perform, of the form [[method_name, args], [...], ...]
	def update_relation(args)
	    unmarshall_and_update(args) do |args|
	        Roby::Distributed.debug { "received update from #{peer.name}: #{args[0]}.#{args[1]}(#{args[2..-1].join(", ")})" }
	        args[0].send(*args[1..-1])
	    end
	end


	def unmarshall_and_update(args)
	    updating = []
	    args.map! do |o|
		if o.respond_to?(:remote_object)
		    proxy = peer.proxy(o)
		    updating << proxy
		    proxy
		else o
		end
	    end
	    Roby::Distributed.update(*updating) do 
		yield(args)
	    end
	    nil
	end
    end
    allow_remote_access PeerServer

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
		peer = connection_space.peers.find { |ts, peer| ts.remote_id == tuplespace.remote_id }
		peer = peer.last if peer

		if peer
		    next if peer.connected?
		    Roby::Distributed.debug { "Peer #{peer} finalized handshake" }
		    # The peer finalized the handshake
		    peer.connected = true
		elsif neighbour = connection_space.neighbours.find { |n| n.tuplespace.remote_id == tuplespace.remote_id }
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
	    @name	  = neighbour.name
	    @local        = PeerServer.new(self)
	    @proxies	  = Hash.new
	    @send_flushed = new_cond
	    @max_allowed_errors = connection_space.max_allowed_errors
	    connection_space.peers[neighbour.tuplespace] = self

	    connect
	end

	attr_reader :name, :max_allowed_errors

	def send(*args, &block)
	    Roby::Distributed.debug { "queueing #{neighbour.name}.#{args[0]}" }
	    @send_queue.push([[remote_server, args], block])
	    @sending = true
	end

	def send_thread
	    @send_queue = Queue.new
	    @send_thread = Thread.new do
		error_count = 0
		while calls ||= @send_queue.get
		    break unless connected?
		    while !alive?
			break unless connected?
			connection_space.wait_discovery
		    end

		    # Mux all calls into one array and send them
		    synchronize do
			calls += @send_queue.get(true)
			Roby::Distributed.debug { "sending #{calls.size} commands to #{neighbour.name}" }
			success, error = begin remote_server.demux(calls.map { |a| a.first })
					 rescue; [0, $!]
					 end
			Roby::Distributed.debug { "#{neighbour.name} processed #{success} commands" }
			(0...success).each do |i|
			    if block = calls[i][1]
				block.call rescue nil
			    end
			end

			error_count = 0 if success > 0
			if error
			    Roby::Distributed.warn  { "#{name} reports an error on #{calls[success][1..-1]}: #{error.to_s}" }
			    Roby::Distributed.debug { error.full_message }
			    if DRb::DRbConnError === error
				# We have a connection error, mark the connection as not being alive
				dead_connection!
			    end

			    calls = calls[success..-1]
			    error_count += 1
			else
			    calls = nil
			    @sending = !@send_queue.empty?
			    send_flushed.broadcast unless @sending
			end

			if (error_count += 1) > self.max_allowed_errors
			    Roby::Distributed.fatal do
				"#{name} disconnecting from #{neighbour.name} because of too much errors"
			    end
			    disconnect
			    break
			end
		    end
		end

		Roby::Distributed.debug "sending thread quit for #{neighbour.name}"
		@sending = nil
		@send_queue.clear
		synchronize do
		    send_flushed.broadcast
		end
	    end
	end

	# Flushes all commands that are currently queued for this peer. Returns
	# true if there were commands waiting, false otherwise
	def flush
	    synchronize do
		return false unless @sending
		send_flushed.wait
	    end
	    true
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
	rescue Rinda::RequestExpiredError
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
    
	def dead_connection!
	    connection_space.take({'kind' => :peer, 'tuplespace' => neighbour.tuplespace, 'remote' => nil}, 0)
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

	# Get a proxy for a task or an event. If +as+ is given, the proxy will be acting
	# as-if +object+ is of class +as+. This can be used to map objects whose
	# model we don't know (while we know a more abstract model)
	def proxy(marshalled)
	    object = marshalled.remote_object
	    @proxies[object] ||= marshalled.proxy(self)
	    connection_space.plan.discover(@proxies[object])

	    @proxies[object]
	end

	# Check if +object+ should be proxied
	def proxying?(object)
	    object.respond_to?(:remote_object)
	end

	# Discovers all objects at a distance +dist+ from +obj+. The object
	# can be either a remote proxy or the remote object itself
	def discover_neighborhood(object, distance)
	    send(:discover_neighborhood, object.remote_object, distance)
	end

	# Make the remote pDB send us all updates about +object+
	def subscribe(object)
	    send(:subscribe, object.remote_object)
	end
	def unsubscribe(object, remove_object = true)
	    unless object.kind_of?(RemoteObjectProxy)
		object = proxy(object)
	    end

	    send(:unsubscribe, object.remote_object) do
		if remove_object && object.kind_of?(Roby::Task)
		    connection_space.plan.remove_task(object)
		end
	    end
	end
    end
end

