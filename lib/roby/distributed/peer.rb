require 'roby/control'
require 'roby/plan'
require 'roby/distributed/proxy'
require 'utilrb/queue'
require 'utilrb/array/to_s'

module Roby
    class Control; include DRbUndumped end
end

module Roby::Distributed
    # Base class for all communication errors
    class ConnectionError   < RuntimeError; end
    # The peer is connected but connection is not alive
    class NotAliveError     < ConnectionError; end
    # The peer is disconnected
    class DisconnectedError < ConnectionError; end

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
	    if !peer.connected?
		raise Disconnected, "#{server_name} has been disconnected"
	    end

	    result = []
	    calls.each do |obj, args|
		Roby::Distributed.debug { "processing #{obj}.#{args[0]}(#{args[1..-1].join(", ")})" }
		result << obj.send(*args)
	    end

	    [result, nil]

	rescue
	    [result, $!]
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

	    relations = subscribed_relations(object)
	    # Send event event if +result+ is empty, so that relations are
	    # removed if needed on the other side
	    peer.send(:set_relations, object, relations)

	    if object.respond_to?(:each_event)
		object.each_event(false, &method(:subscribe))
	    end
	    nil
	end
	def subscribed?(object); subscriptions.include?(object) end

	def subscribed_relations(object)
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

	    result
	end

	def unsubscribe(object)
	    subscriptions.delete(object)
	    if object.respond_to?(:each_event)
		object.each_event(&method(:unsubscribe))
	    end
	    nil
	end
	def create_transaction(remote_trsc)
	    if dtrsc = (peer.proxy(remote_trsc) rescue nil)
		raise ArgumentError, "#{remote_trsc} is already created"
	    end

	    plan = peer.proxy(remote_trsc.plan)
	    trsc = Roby::Distributed::Transaction.new(plan)
	    trsc.owners.merge(remote_trsc.owners)
	    trsc.remote_siblings[peer.remote_id] = remote_trsc.remote_object
	    trsc
	end
	
	# Sets all tasks and all relations in +trsc+. This is only valid if the local
	# copy of +trsc+ is empty
	def set_transaction(remote_trsc, missions, tasks, free_events)
	    trsc = peer.proxy(remote_trsc)
	    unless trsc.empty?(true)
		raise ArgumentError, "#{trsc} is not empty"
	    end

	    proxies = []
	    missions.each do |marshalled_task| 
		task = peer.proxy(marshalled_task)
		trsc.insert(task)
		peer.subscribe(marshalled_task)
		proxies << task
	    end
	    tasks.each do |marshalled_task| 
		task = peer.proxy(marshalled_task)
		trsc.discover(task)
		peer.subscribe(marshalled_task)
		proxies << task
	    end

	    # and subscribe the peer to all the local tasks
	    subscriptions.merge(proxies)
	end

	def apply(args)
	    args = args.map do |a|
		if peer.proxying?(a)
		    peer.proxy(a)
		else a
		end
	    end
	    if block_given? then yield(args)
	    else args
	    end
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
			    Roby::Distributed.update([from, to]) do
				from.add_child_object(to, graph, info)
			    end
			end
		    end
		end
	    end

	    object.each_relation do |rel|
		# Remove relations that do not exist anymore
		(object.parent_objects(rel) - parents[rel]).each do |p|
		    if peer.owns?(p)
			Roby::Distributed.update([p, object]) do
			    p.remove_child_object(object, rel)
			end
		    end
		end
		(object.child_objects(rel) - children[rel]).each do |c|
		    if peer.owns?(c)
			Roby::Distributed.update([c, object]) do
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
		if peer.proxying?(o)
		    proxy = peer.proxy(o)
		    updating << proxy
		    proxy
		else o
		end
	    end
	    Roby::Distributed.update(updating) do 
		yield(args)
	    end
	    nil
	end

	def prepare_transaction_commit(trsc)
	    Roby::Control.once { peer.connection_space.prepare_transaction_commit(peer.proxy(trsc)) }
	end
	def commit_transaction(trsc)
	    Roby::Control.once { peer.connection_space.commit_transaction(peer.proxy(trsc)) }
	end
	def abandon_commit(trsc)
	    Roby::Control.once { peer.connection_space.abandon_commit(peer.proxy(trsc)) }
	end
	def discard_transaction(trsc)
	    Roby::Control.once { peer.connection_space.discard_transaction(peer.proxy(trsc)) }
	end
    end
    allow_remote_access PeerServer

    class Peer
	# The local ConnectionSpace object we act on
	attr_reader :connection_space
	# The local PeerServer object for this peer
	attr_reader :local
	# The neighbour object describing our peer
	attr_reader :neighbour
	# The last 'keepalive' tuple we wrote on the neighbour's ConnectionSpace
	attr_reader :keepalive

	include MonitorMixin
	attr_reader :send_flushed

	def name; neighbour.name end

	# Listens for new connections on Distributed.state
	def self.connection_listener(connection_space)
	    connection_space.read_all( { 'kind' => :peer, 'connection_space' => nil, 'remote' => nil } ).each do |entry|
		remote_cs = entry['connection_space']
		peer = connection_space.peers[remote_cs]

		if peer
		    next if peer.connected?
		    Roby::Distributed.debug { "Peer #{peer.name} finalized handshake" }
		    # The peer finalized the handshake
		    peer.connected = true
		elsif neighbour = connection_space.neighbours.find { |n| n.connection_space == remote_cs }
		    Roby::Distributed.debug { "Peer #{remote_cs.name} asking for connection" }
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

	    connection_space.peers[remote_id] = self
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
			results, error = begin remote_server.demux(calls.map { |a| a.first })
					 rescue; [[], $!]
					 end
			success = results.size
			Roby::Distributed.debug { "#{neighbour.name} processed #{success} commands" }
			(0...success).each do |i|
			    if block = calls[i][1]
				block.call(results[i]) rescue nil
			    end
			end

			error_count = 0 if success > 0
			if error
			    Roby::Distributed.warn  do
				call = calls[success].first
				 "#{name} reports an error on #{call[0]}.#{call[1]}(#{call[2..-1].join(", ")})"
			    end
			    Roby::Distributed.debug { "\n" + error.full_message }
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
		neighbour.connection_space.write({ 'kind' => :peer, 'connection_space' => connection_space, 'remote' => @local }, timeout)

	    old.cancel if old
	end

	# Disconnects from the peer
	def disconnect
	    connection_space.peers.delete(remote_id)
	    @connected = false
	    keepalive.cancel if keepalive

	    neighbour.connection_space.take({ 'kind' => :peer, 'connection_space' => neighbour.connection_space, 'remote' => nil }, 0)
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
	    connection_space.take({'kind' => :peer, 'connection_space' => neighbour.connection_space, 'remote' => nil}, 0)
	end
	def owns?(object); object.owners.include?(remote_id) end

	# Checks if the connection is currently alive
	def alive?
	    return false unless connected?
	    return false unless connection_space.neighbours.find { |n| n.connection_space == neighbour.connection_space }
	    @entry = connection_space.read({'kind' => :peer, 'connection_space' => neighbour.connection_space, 'remote' => nil}, 0) rescue nil
	    return !!@entry
	end

	# Get direct access to the remote plan
	def plan; remote_server.plan.remote_object end

	# Get a proxy for a task or an event. If +as+ is given, the proxy will be acting
	# as-if +object+ is of class +as+. This can be used to map objects whose
	# model we don't know (while we know a more abstract model)
	def proxy(marshalled)
	    object = marshalled.remote_object
	    return object unless object.kind_of?(DRbObject)
	    object_proxy = (@proxies[object] ||= marshalled.proxy(self))

	    # marshalled.plan is nil if the object plan is determined by another
	    # object. For instance, in the TaskEventGenerator case, the generator
	    # plan is the task plan
	    if marshalled.kind_of?(MarshalledPlanObject) && marshalled.plan
		proxy(marshalled.plan).discover(object_proxy)
	    end
	    object_proxy
	end

	# Check if +object+ should be proxied
	def proxying?(marshalled)
	    marshalled.respond_to?(:remote_object) && marshalled.respond_to?(:proxy)
	end

	# Discovers all objects at a distance +dist+ from +obj+. The object
	# can be either a remote proxy or the remote object itself
	def discover_neighborhood(marshalled, distance)
	    send(:discover_neighborhood, marshalled, distance)
	end

	# Make the remote pDB send us all updates about +object+
	def subscribe(marshalled)
	    send(:subscribe, marshalled.remote_object)
	end
	def unsubscribe(marshalled, remove_object = true)
	    # Get the proxy for +marshalled+
	    proxy = proxy(marshalled)
	    if linked_to_local?(proxy)
		raise InvalidRemoteOperation, "cannot unsubscribe to a task still linked to local tasks"
	    end

	    send(:unsubscribe, marshalled.remote_object) do
		proxy = proxy(marshalled)
		if remove_object && proxy.kind_of?(Roby::Task)
		    connection_space.plan.remove_task(proxy)
		end
	    end
	end

	# Create a sibling for +trsc+ on this peer. If a block is given, yields
	# the remote transaction object from within the communication thread
	def create_transaction(trsc)
	    unless trsc.kind_of?(Roby::Distributed::Transaction)
		raise TypeError, "cannot create a non-distributed transaction"
	    end

	    send(:create_transaction, trsc) do |remote_transaction|
		remote_transaction = remote_transaction.remote_object
		trsc.remote_siblings[remote_id] = remote_transaction
		yield(remote_transaction) if block_given?
	    end
	end
	def propose_transaction(trsc)
	    # What do we need to do on the remote side ?
	    #   - create a new transaction with the right owners
	    #   - create all needed transaction proxys. Transaction proxys
	    #     can apply on local and remote tasks
	    #   - create all needed remote proxys
	    #   - setup all relations
	    peer_missions = trsc.missions(true)
	    peer_tasks    = trsc.known_tasks(true) - peer_missions
	    free_events   = trsc.free_events

	    create_transaction(trsc) do |ret|
		send(:set_transaction, trsc, peer_missions, peer_tasks, free_events)
	    end
	end

	def remote_id; neighbour.connection_space end

	def find_plan(plan)
	    base_plan = connection_space.plan
	    if plan.kind_of?(DRbObject)
		find_transaction(plan, base_plan)
	    elsif plan.nil?
		base_plan
	    end
	end
	def find_transaction(trsc, base_plan = nil)
	    (base_plan || connection_space.plan).transactions.each do |t|
		if t.respond_to?(:remote_siblings) && t.remote_siblings[remote_id] == trsc
		    return t
		elsif found = find_transaction(trsc, t)
		    return found
		end
	    end

	    nil
	end
    end
end

