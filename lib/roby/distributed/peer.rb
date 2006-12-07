require 'roby/control'
require 'roby/plan'
require 'roby/distributed/notifications'
require 'roby/distributed/proxy'
require 'roby/relations/executed_by'
require 'roby/transactions'
require 'utilrb/queue'
require 'utilrb/array/to_s'
require 'set'

module Roby
    class Control; include DRbUndumped end
end

module Roby::Distributed
    class ConnectionTask < Roby::Task
	event :ready
	local_object
    end
    class LiveConnectionTask < Roby::Task
	local_object
    end

    # Base class for all communication errors
    class ConnectionError   < RuntimeError; end
    # The peer is connected but connection is not alive
    class NotAliveError     < ConnectionError; end
    # The peer is disconnected
    class DisconnectedError < ConnectionError; end

    @updated_objects = ValueSet.new
    class << self
	def each_subscribed_peer(*objects)
	    return if objects.any? { |o| !o.distribute? }
	    peers.each do |name, peer|
		next if objects.any? { |o| !o.has_sibling?(peer) }
		yield(peer) if objects.any? { |o| peer.local.subscribed?(o) || peer.owns?(o) }
	    end
	end

	# The list of objects that are being updated because of remote update
	attr_reader :updated_objects

	# If we are updating all objects in +objects+
	def updating?(objects)
	    updated_objects.include_all?(objects) 
	end

	# Call the block with the objects in +objects+ added to the
	# updated_objects set
	def update(objects)
	    old_updated = updated_objects
	    @updated_objects |= objects

	    yield

	ensure
	    @updated_objects = old_updated
	end
    end

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
		next unless rel.distribute? && from.distribute? && to.distribute?
		[peer.remote_server, [:update_relation, [from, :add_child_object, to, rel, info]]]
	    end
	    peer.transmit(:demux, edges)
	    nil
	end

	def subscribe(object)
	    object = peer.proxy(object)
	    return if subscribed?(object)
	    subscriptions << object

	    case object
	    when Roby::PlanObject
		# Send event event if +result+ is empty, so that relations are
		# removed if needed on the other side
		relations = relations_of(object)
		peer.transmit(:set_relations, object, relations)

		if object.respond_to?(:each_event)
		    object.each_event do |ev|
			# Send event event if +result+ is empty, so that relations are
			# removed if needed on the other side
			relations = relations_of(ev)
			peer.transmit(:set_relations, ev, relations)
		    end
		end

	    when Roby::Transaction
		peer.transmit(:set_plan, object, 
		    object.missions(true).find_all { |t| t.distribute? }, 
		    object.known_tasks(true).find_all { |t| t.distribute? })
	    when Roby::Plan
		peer.transmit(:set_plan, object, 
		    object.missions.find_all { |t| t.distribute? }, 
		    object.known_tasks.find_all { |t| t.distribute? })
	    end

	    nil
	end
	def subscribed?(object); subscriptions.include?(object) end

	def relations_of(object)
	    result = []
	    object.each_graph do |graph|
		next unless graph.distribute?

		graph_edges = []
		object.each_child_object(graph) do |child|
		    next unless child.distribute?
		    graph_edges << [object, child, object[child, graph]]
		end
		object.each_parent_object(graph) do |parent|
		    next unless parent.distribute?
		    graph_edges << [parent, object, parent[object, graph]]
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
			    Roby::Distributed.update([from.root_object, to.root_object]) do
				from.add_child_object(to, graph, info)
			    end
			end
		    end
		end
	    end

	    object.each_relation do |rel|
		# Remove relations that do not exist anymore
		(object.parent_objects(rel) - parents[rel]).each do |p|
		    Roby::Distributed.update([p.root_object, object.root_object]) do
			p.remove_child_object(object, rel)
		    end
		end
		(object.child_objects(rel) - children[rel]).each do |c|
		    Roby::Distributed.update([c.root_object, object.root_object]) do
			object.remove_child_object(c, rel)
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
	    updating = ValueSet.new
	    args = [args] unless args.respond_to?(:map)
	    args = args.map do |o|
		if peer.proxying?(o)
		    proxy = peer.proxy(o)
		    if proxy.kind_of?(Roby::PlanObject)
			updating << proxy.root_object
		    end
		    proxy
		else o
		end
	    end
	    Roby::Distributed.update(updating) do 
		yield(args)
	    end
	    nil
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
		    peer.connected!
		elsif neighbour = connection_space.neighbours.find { |n| n.connection_space == remote_cs }
		    Roby::Distributed.debug { "Peer #{remote_cs.name} asking for connection" }
		    # New connection attempt from a known neighbour
		    Peer.new(connection_space, neighbour).connected!
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

	attr_reader :name, :max_allowed_errors, :task

	def transmit(*args, &block)
	    Roby::Distributed.debug { "queueing #{neighbour.name}.#{args[0]}" }
	    @send_queue.push([[remote_server, args], block])
	    @sending = true
	end

	def send_thread
	    @send_queue = Queue.new
	    @send_thread = Thread.new do
		begin
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
					     rescue Exception; [[], $!]
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

		rescue Exception
		    STDERR.puts "Communication thread dies with\n#{$!.full_message}"
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

	# Writes a connection tuple into the peer tuplespace
	# We consider that two peers are connected when there
	# is this kind of tuple in *both* tuplespaces
	def connect
	    raise "Already connected" if connected?

	    @task = ConnectionTask.new
	    connection_space.plan.insert(task)
	    task.event(:start).emit(nil)
	    ping
	end

	# Called when the handshake is finished
	def connected!
	    send_thread
	    task.event(:ready).emit(nil)
	end

	# Updates our keepalive token on the peer
	def ping(timeout = nil)
	    old, @keepalive = @keepalive, 
		neighbour.connection_space.write({ 'kind' => :peer, 'connection_space' => connection_space, 'remote' => @local }, timeout)

	    old.cancel if old
	end

	def disconnect
	    keepalive.cancel if keepalive
	    neighbour.connection_space.take( { 
		'kind' => :peer, 
		'connection_space' => neighbour.connection_space, 
		'remote' => nil }, 0)

	    connection_space.peers.delete(remote_id)

	    send_queue.push(nil)
	    @send_thread.join
	    @send_queue.clear
	    @send_thread = nil

	    task.event(:failed).emit(nil)

	rescue Rinda::RequestExpiredError
	end

	# Returns true if the connection has been established. See also #alive?
	def connected?; task && task.running? && task.event(:ready).happened? end

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
	    return marshalled unless proxying?(marshalled)
	    if marshalled.respond_to?(:remote_object)
		object = marshalled.remote_object
		return object unless object.kind_of?(DRbObject)
		unless object_proxy = @proxies[object]
		    object_proxy = @proxies[object] = marshalled.proxy(self)

		    if object_proxy.respond_to?(:execution_agent) && object_proxy.plan
			connection_task = object_proxy.plan[self.task]
			Roby::Distributed.update([object_proxy, connection_task]) do
			    # Get the proxy plan
			    object_proxy.executed_by connection_task
			end
		    end
		end
		if marshalled.respond_to?(:update)
		    marshalled.update(self, object_proxy) 
		end
	    else
		object_proxy = marshalled.proxy(self)
	    end

	    object_proxy
	end

	# Check if +object+ should be proxied
	def proxying?(marshalled)
	    marshalled.respond_to?(:proxy)
	end

	# Discovers all objects at a distance +dist+ from +obj+. The object
	# can be either a remote proxy or the remote object itself
	def discover_neighborhood(marshalled, distance)
	    transmit(:discover_neighborhood, marshalled, distance)
	end

	# DO NOT USE a ValueSet here. We use DRbObjects to track subscriptions
	# on this side, and they must be compared using #==
	attribute(:subscriptions) { Set.new }

	# Make the remote pDB send us all updates about +object+
	def subscribe(marshalled)
	    transmit(:subscribe, marshalled.remote_object) do
		subscriptions << marshalled.remote_object
	    end
	end
	def subscribed?(remote_object)
	    subscriptions.include?(remote_object)
	end

	# Returns true if +object+ is related to any local task
	def linked_to_local?(proxy)
	    proxy.each_relation do |rel|
		if proxy.child_objects(rel).any? { |child| !child.kind_of?(RemoteObjectProxy) }
		    return true
		end
		if proxy.parent_objects(rel).any? { |child| !child.kind_of?(RemoteObjectProxy) }
		    return true
		end
	    end
	    false
	end

	def remove_unsubscribed_relations(proxy)
	    keep_proxy = false
	    proxy.related_tasks.each do |task|
		if task.kind_of?(RemoteObjectProxy) && task.peer_id == remote_id && 
		    !subscribed?(task.remote_object(remote_id))

		    connection_space.plan.remove_task(task)
		else keep_proxy = true
		end
	    end
	    unless keep_proxy
		connection_space.plan.remove_object(proxy)
	    end
	end

	def unsubscribe(marshalled, remove_object = true)
	    # Get the proxy for +marshalled+
	    proxy = proxy(marshalled)
	    case proxy
	    when Roby::PlanObject
		if linked_to_local?(proxy)
		    raise InvalidRemoteOperation, "cannot unsubscribe to a task still linked to local tasks"
		end

		transmit(:unsubscribe, marshalled.remote_object) do
		    subscriptions.delete(marshalled.remote_object)
		    if remove_object && proxy.kind_of?(Roby::Task)
			remove_unsubscribed_relations(proxy)
		    end
		end

	    else
		transmit(:unsubscribe, marshalled.remote_object)
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

