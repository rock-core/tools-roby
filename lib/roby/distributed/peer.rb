require 'set'
require 'utilrb/queue'
require 'utilrb/array/to_s'

require 'roby'
require 'roby/state'
require 'roby/planning'
require 'roby/distributed/notifications'
require 'roby/distributed/proxy'
require 'roby/distributed/communication'

module Roby
    class Control; include DRbUndumped end
end

module Roby::Distributed
    class ConnectionTask < Roby::Task
	event :ready
	local_object
	def ready?; event(:ready).happened? end

	def peer; arguments[:peer] end

	def failed(context); end # Peer#connection_listener checks if 'failed' is pending to initiate the disconnection
	event :failed, :terminal => true

	def stop(context); failed!(context) end
	event :stop
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

    # Performs a plan query on a remote plan. See Peer#query
    class RemoteQuery
	attr_reader :peer, :matcher
	def initialize(peer)
	    @peer    = peer
	    @matcher = Roby::TaskMatcher.new
	end
	def method_missing(name, *args, &block)
	    @matcher.send(name, *args, &block)
	    self
	end

	def each(&block)
	    peer.remote_server.query(matcher).each(&block)
	end
	include Enumerable
    end

    @updated_objects = ValueSet.new
    class << self
	def each_subscribed_peer(*objects)
	    return if objects.any? { |o| !o.distribute? }
	    peers.each do |name, peer|
		next unless peer.connected?
		next if objects.any? { |o| !o.has_sibling?(peer) }
		yield(peer) if objects.any? { |o| peer.local.subscribed?(o) || peer.owns?(o) }
	    end
	end
	
	def trigger(*objects)
	    # If +object+ is a trigger, send the :triggered event but do *not*
	    # act as if +object+ was subscribed
	    peers.each do |name, peer|
		peer.local.trigger(*objects)
	    end
	end
	# Remove +objects+ from the sets of already-triggered objects
	def clean_triggered(*objects)
	    objects = objects.to_value_set
	    peers.each do |name, peer|
		peer.local.triggers.each do |id, (matcher, triggered)|
		    peer.local.triggers[id] = [matcher, triggered.difference(triggered)]
		end
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
	attr_reader :triggers

	def initialize(peer)
	    @peer	    = peer 
	    @subscriptions  = ValueSet.new
	    @triggers	    = Hash.new
	end

	# Activate any trigger that may exist on +objects+
	def trigger(*objects)
	    triggers.each do |id, (matcher, triggered)|
		objects.each do |object|
		    if !triggered.include?(object) && matcher === object
			triggered << object
			peer.transmit(:triggered, id, object)
		    end
		end
	    end
	end

	# The name of the local ConnectionSpace object we are acting on
	def local_name; peer.local_name end
	# The name of the remote peer
	def remote_name; peer.remote_name end
	
	# The plan object which is used as a facade for our peer
	def plan; peer.connection_space.plan end

	# Applies +matcher+ on the local plan and sends back the result
	def query(matcher)
	    matcher.enum_for(:each, plan).to_a
	end

	# The peers asks to be notified if a plan object which matches
	# +matcher+ changes
	def add_trigger(id, matcher)
	    triggers[id] = [matcher, (triggered = ValueSet.new)]
	    Roby.info "#{remote_name} wants notification on #{matcher} (#{id})"

	    matcher.each(plan) do |task|
		triggered << task
		peer.transmit(:triggered, id, task)
	    end
	    nil
	end

	# Remove the trigger +id+ defined by this peer
	def remove_trigger(id)
	    Roby.info "#{remote_name} removed #{id} notification"
	    triggers.delete(id)
	    nil
	end

	# The peer tells us that +task+ has triggered the notification +id+
	def triggered(id, task)
	    peer.triggered(id, task) 
	    nil
	end

	def state_update(new_state)
	    peer.state = new_state
	end

	# Send the neighborhood of +distance+ hops around +object+ to the peer
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

	# Relations to be sent to the remote host if +object+ is in a plan. The
	# returned array if formatted as [ [graph, graph_edges], [graph, ..] ]
	# where graph_edges is [[parent, child, data], ...]
	def relations_of(object)
	    result = []
	    # For transaction proxies, never send non-discovered relations to
	    # remote hosts
	    enumerate_with = if object.respond_to?(:each_discovered_relation)
				 "each_discovered_relation"
			     else "each_relation"
			     end

	    object.send(enumerate_with) do |graph|
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

	# Returns the commands to be fed to #set_relations in order to copy
	# the state of plan_object on the remote peer
	#
	# The returned relation sets can be empty if the plan object does not
	# have any relations. Since the goal is to *copy* the graph relations...
	def set_relations_commands(plan_object, relations = [])
	    relations << [peer.remote_server, [:set_relations, plan_object, relations_of(plan_object)]]

	    if plan_object.respond_to?(:each_event)
		plan_object.each_event do |ev|
		    # Send event even if +result+ is empty, so that relations
		    # are removed if needed on the other side
		    relations << [peer.remote_server, [:set_relations, ev, relations_of(ev)]]
		end
	    end
	    relations
	end

	# Called by the peer to subscribe on +object+. Returns an array which
	# is to be fed to #demux to update the object relations on the remote
	# host
	def subscribe(object)
	    object = peer.proxy(object)
	    return if subscribed?(object)
	    subscriptions << object

	    case object
	    when Roby::PlanObject
		set_relations_commands(object)

	    when Roby::Plan
		missions, tasks = if object.kind_of?(Roby::Transaction)
				      [object.missions(true), object.known_tasks(true)]
				  else
				      [object.missions, object.known_tasks]
				  end

		missions.delete_if { |el| !el.distribute? }
		tasks.delete_if { |el| !el.distribute? }

		relations = tasks.inject([]) do |relations, t| 
		    subscriptions << t
		    set_relations_commands(t, relations)
		end

		[[peer.remote_server, [:subscribed_plan, object, missions, tasks, relations]]]
	    end
	end

	# The peer asks to be unsubscribed from +object+
	def unsubscribe(object)
	    subscriptions.delete(object)
	    if object.respond_to?(:each_event)
		object.each_event(&method(:unsubscribe))
	    end
	    nil
	end

	# Check if changes to +object+ should be notified to this peer
	def subscribed?(object)
	    subscriptions.include?(object)
	end

	def apply(args)
	    args = args.map do |a|
		if peer.proxying?(a)
		    peer.proxy(a)
		else a
		end
	    end.compact
	    if block_given? then yield(args)
	    else args
	    end
	end

	# Receive the list of relations of +object+. The relations are given in
	# an array like [[graph, from, to, info], [...], ...]
	def set_relations(object, relations)
	    return unless object = peer.proxy(object)
	    Roby::Distributed.update([object]) do
		parents  = Hash.new { |h, k| h[k] = Array.new }
		children = Hash.new { |h, k| h[k] = Array.new }
		
		# Add or update existing relations
		relations.each do |graph, graph_relations|
		    graph_relations.each do |args|
			apply(args) do |from, to, info|
			    if !from || !to
				next
			    elsif to == object
				parents[graph]  << from
			    elsif from == object
				children[graph] << to
			    else
				raise ArgumentError, "trying to set a relation #{from.inspect} -> #{to.inspect} in which self(#{object.inspect}) in neither parent nor child"
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

		enumerator = if object.respond_to?(:each_discovered_relation) then :each_discovered_relation
			     else :each_relation
			     end

		object.send(enumerator) do |rel|
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
	    end

	    nil
	end

	# Receive an update on the relation graphs
	def update_relation(args)
	    unmarshall_and_update(args) do |args|
	        Roby::Distributed.debug { "received update from #{remote_name}: #{args[0]}.#{args[1]}(#{args[2..-1].join(", ")})" }
	        args[0].send(*args[1..-1])
	    end
	    nil
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
	    end.compact
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
	# The tuple describing our peer
	attr_accessor :tuple
	# The server object we use to access the remote plan database
	def remote_server; tuple['remote'] end
	# The neighbour object describing our peer
	attr_reader :neighbour
	# The last 'keepalive' tuple we wrote on the neighbour's ConnectionSpace
	attr_reader :keepalive

	include MonitorMixin
	attr_reader :send_flushed

	# The name of the remote peer
	def remote_name; neighbour.name end
	# The name of the local ConnectionSpace object we are acting on
	def local_name; connection_space.name end

	# The ID => block hash of all triggers we have defined on the remote plan
	attr_reader :triggers

	# The remote state
	def state; tuple['state'] end

	# Listens for new connections on Distributed.state
	def self.connection_listener(connection_space)
	    seen = []

	    connection_space.tuplespace.read_all( { 'kind' => :peer, 'tuplespace' => nil, 'remote' => nil, 'state' => nil } ).each do |entry|
		remote_ts = entry['tuplespace']
		seen << remote_ts
		peer = connection_space.peers[remote_ts]

		if peer 
		    if peer.task.event(:failed).pending?
			peer.disconnect
		    elsif peer.connecting?
			# The peer finalized the handshake
			peer.connected!
		    elsif peer.connected?
			# ping the remote host
			peer.ping
			# update the host state
			peer.tuple = entry
		    end
		elsif neighbour = connection_space.neighbours.find { |n| n.tuplespace == remote_ts }
		    Roby::Distributed.info { "peer #{neighbour.name} asking for connection" }
		    # New connection attempt from a known neighbour
		    Peer.new(connection_space, neighbour).connected!
		end
	    end

	    (connection_space.peers.keys - seen).each do |disconnected| 
		next if connection_space.peers[disconnected].connecting?

		Roby::Distributed.debug { "peer #{connection_space.peers[disconnected].remote_name} disconnected" }
		connection_space.peers[disconnected].disconnected!
		connection_space.peers.delete(disconnected)
	    end
	end

	# Creates a Peer object for +neighbour+, which is managed by
	# +connection_space+.  If a block is given, it is called in the control
	# thread when the connection is finalized
	def initialize(connection_space, neighbour, &block)
	    if neighbour.peer
		raise ArgumentError, "there is already a peer for #{neighbour.name}"
	    end
	    super() if defined? super

	    @connection_space = connection_space
	    @neighbour	  = neighbour
	    @local        = PeerServer.new(self)
	    @proxies	  = Hash.new
	    @send_flushed = new_cond
	    @max_allowed_errors = connection_space.max_allowed_errors
	    @triggers = Hash.new

	    neighbour.peer = connection_space.peers[remote_id] = self
	    connect(&block)
	end

	attr_reader :name, :max_allowed_errors, :task
	

	# Creates a query object on the peer plan
	def query
	    RemoteQuery.new(self)
	end


	# call-seq:
	#   peer.on(matcher) { |task| ... }	=> ID
	#
	# Call the provided block in the control thread when a task matching
	# +matcher+ has been found on the remote plan. +task+ is the local
	# proxy for the matching remote task.
	#
	# The return value is an identifier which can be later used to remove
	# the trigger with Peer#remove_trigger
	def on(matcher, &block)
	    triggers[matcher.object_id] = [matcher, block]
	    transmit(:add_trigger, matcher.object_id, matcher)
	end

	# Remote a trigger from its ID. +id+ is the return value of Peer#on
	def remove_trigger(id)
	    transmit(:remove_trigger, id)
	    triggers.delete(id)
	end

	# Calls the block given to Peer#on when +task+ has matched the trigger
	def triggered(id, task) # :nodoc:
	    if trigger = triggers[id]
		trigger.last.call(proxy(task))
	    end
	end

	attr_reader :connection_state

	# Initiates a connection with this peer. This inserts a new
	# ConnectionTask task in the plan and starts it. When the connection is
	# complete (the peer has finalized the handshake), the 'ready' event of
	# this task is emitted.
	def connect
	    raise if task
	    @connection_state = :connecting

	    @task = ConnectionTask.new :peer => self
	    if block_given?
		task.on(:ready) { yield(self) }
	    end

	    Roby::Control.once do
		connection_space.plan.permanent(task)
		task.event(:start).emit(nil)
	    end
	    ping
	end

	# Called when the handshake is finished. After this call, the
	# connection task has emitted its 'ready' event and the connection is
	# alive
	def connected! # :nodoc:
	    raise "not connecting" unless connecting?
	    @connection_state = :connected

	    @send_queue = Queue.new
	    @send_thread = Thread.new(&method(:communication_loop))

	    @tuple = connection_space.tuplespace.read(
		    {'kind' => :peer, 'tuplespace' => neighbour.tuplespace, 'remote' => nil, 'state' => nil}, 
		    0)

	    Roby::Control.once { task.event(:ready).emit(nil) }
	    Roby::Distributed.info { "connected to #{neighbour.name}" }
	end

	# Updates our keepalive token on the peer
	def ping(timeout = nil)
	    @dead = false
	    return unless link_alive?

	    old, @keepalive = @keepalive, 
		neighbour.tuplespace.write(
		    { 'kind' => :peer, 'tuplespace' => connection_space.tuplespace, 'remote' => @local, 'state' => Roby::State }, 
		    timeout)

	    old.cancel if old

	rescue DRb::DRbConnError => e
	    Roby.debug "failed to ping #{remote_name}: #{e.full_message}"
	    link_dead!
	rescue RangeError
	    # Looks like the remote side is not what we thought it was. It may be for instance that it died
	    # and restarted. Whatever. Kill the connection
	    @keepalive = nil
	    disconnect
	    disconnected!
	end

	# Disconnect this side of the connection. The remote host is supposed
	# to acknowledge that by removing its last keepalive tuple from our
	# connection space.
	#
	# The 'failed' event is emitted on the ConnectionTask task
	def disconnect
	    return if disconnecting?
	    @connection_state = :disconnecting

	    # Remove the keepalive tuple we wrote on the remote host
	    if keepalive
		keepalive.cancel rescue Rinda::RequestExpiredError
	    end

	    @send_queue.push(nil)
	    unless Thread.current == @send_thread
		@send_thread.join
	    end
	    @send_thread = nil
	end

	# Called when the peer acknowledged the fact that we disconnected
	def disconnected! # :nodoc:
	    disconnect if connected?
	    @connection_state = nil

	    Roby::Distributed.info "#{neighbour.name} disconnected"
	    connection_space.peers.delete(remote_id)
	    neighbour.peer = nil

	    Roby::Control.once { task.event(:failed).emit(nil) }
	end

	# Returns true if we are establishing a connection with this peer
	def connecting?; connection_state == :connecting end
	# Returns true if the connection has been established. See also #link_alive?
	def connected?; connection_state == :connected end
	# Returns true if the we disconnected on our side but the peer did not
	# acknowledge it yet
	def disconnecting?; connection_state == :disconnecting end

	# Returns true if this peer owns +object+
	def owns?(object); object.owners.include?(remote_id) end

	# Mark the link as dead regardless of the last neighbour discovery. This
	# will be reset during the next neighbour discovery
	def link_dead!; @dead = true end
	# Checks if the connection is currently alive
	def link_alive?
	    return false if @dead
	    return false unless connection_space.neighbours.find { |n| n.tuplespace == neighbour.tuplespace }
	    true
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
		    Roby::Distributed.update([object_proxy]) do
			marshalled.update(self, object_proxy) 
		    end
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
	
	# The set of objects we are subscribed to. This is a set of DRbObject
	attribute(:subscriptions) { Set.new }

	# Subscribe to +marshalled+.	
	def subscribe(remote_object)
	    if remote_object.respond_to?(:remote_object)
		remote_object = remote_object.remote_object(remote_id)
	    end

	    return if subscriptions.include?(remote_object)
	    transmit(:subscribe, remote_object) do |ret|
		subscriptions << remote_object
		if ret
		    error = nil
		    Roby::Distributed.update([remote_object]) do
			_, error = local.demux_local(ret)
		    end
		    raise error if error
		end
		yield if block_given?
	    end
	end

	# True if we are subscribed to +remote_object+ on the peer
	def subscribed?(remote_object)
	    subscriptions.include?(remote_object)
	end

	# Returns true if +proxy+ is related to a local task
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

	# Clears all relations that should be removed because we unsubscribed
	# from +proxy+
	def remove_unsubscribed_relations(proxy) # :nodoc:
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

	# Unsubscribe ourselves from +marshalled+. If +remove_object+ is true,
	# the local proxy for this object is removed from the plan as well
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

	# The object which identifies this peer on the network
	def remote_id; neighbour.tuplespace end

	# Finds the local plan for +plan+
	def find_plan(plan) # :nodoc:
	    base_plan = connection_space.plan
	    if plan.kind_of?(DRbObject)
		find_transaction(plan, base_plan)
	    elsif plan.nil?
		base_plan
	    end
	end

	# Finds the local transaction for +trsc+
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

