require 'roby/control'
require 'roby/plan'
require 'roby/query'
require 'roby/distributed/notifications'
require 'roby/distributed/proxy'
require 'roby/relations/executed_by'
require 'roby/transactions'
require 'roby/state'
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

    class Roby::TaskMatcher
	class Marshalled
	    attr_reader :args
	    def initialize(*args)
		@args = args
	    end

	    def _dump(lvl)
		Roby::Distributed.dump(args)
	    end
	    def self._load(str)
		model, args, improves, needs = Marshal.load(str)
		Roby::TaskMatcher.new.with_model(model).with_arguments(args || {}).
		    which_improves(*improves).which_needs(*needs)
	    end
	end
	def droby_dump
	    Marshalled.new(model, arguments, improved_information, needed_information)
	end
    end

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
	
	def demux(calls)
	    result = []
	    if !peer.connected?
		raise DisconnectedError, "#{remote_name} is disconnected"
	    end

	    from = Time.now
	    calls.each do |obj, args|
		Roby::Distributed.debug { "processing #{obj}.#{args[0]}(#{args[1..-1].join(", ")})" }
		Roby::Control.synchronize do
		    result << obj.send(*args)
		end
	    end
	    Roby.debug "served #{calls.size} calls in #{Time.now - from} seconds"

	    [result, nil]

	rescue Exception
	    [result, $!]
	end

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
	    matcher.each(plan) do |task|
		triggered << task
		peer.transmit(:triggered, id, task)
	    end
	end

	# Remove the trigger +id+ defined by this peer
	def remove_trigger(id)
	    triggers.delete(id)
	end

	# The peer tells us that +task+ has triggered the notification +id+
	def triggered(id, task); peer.triggered(id, task) end

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

	# The peer asked for subscription on +object+
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
			# Send event even if +result+ is empty, so that relations are
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
	def update_relation(args)
	    unmarshall_and_update(args) do |args|
	        Roby::Distributed.debug { "received update from #{remote_name}: #{args[0]}.#{args[1]}(#{args[2..-1].join(", ")})" }
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

	def transmit(*args, &block)
	    if !connected?
		raise DisconnectedError, "we are not currently connected to #{remote_name}"
	    end

	    Roby::Distributed.debug { "queueing #{neighbour.name}.#{args[0]}" }
	    @send_queue.push([[remote_server, args], block])
	    @sending = true
	end

	def communication_loop # :nodoc:
	    error_count = 0
	    while calls ||= @send_queue.get
		return unless connected?
		while !link_alive?
		    return unless connected?
		    connection_space.wait_discovery
		end

		# Mux all calls into one array and send them
		synchronize do
		    calls += @send_queue.get(true)
		    return unless connected?

		    Roby::Distributed.debug { "sending #{calls.size} commands to #{neighbour.name}" }
		    results, error = begin remote_server.demux(calls.map { |a| a.first })
				     rescue Exception
					 [[], $!]
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
			    call = calls[success].first.map do |arg|
				if arg.kind_of?(DRbObject) then arg.inspect
				else arg.to_s
				end
			    end
			    "#{remote_name} reports an error on #{call[0]}.#{call[1]}(#{call[2..-1].join(", ")}):\n#{error.full_message}"
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

			calls = calls[success..-1]
			error_count += 1
		    else
			calls = nil
			@sending = !@send_queue.empty?
			send_flushed.broadcast unless @sending
		    end

		    if error_count > self.max_allowed_errors
			Roby::Distributed.fatal do
				    "#{name} disconnecting from #{neighbour.name} because of too much errors"
			end
			disconnect
		    end
		end
	    end

	rescue Exception
	    Roby::Distributed.fatal "Communication thread dies with\n#{$!.full_message}"

	ensure
	    @send_queue.clear
	    synchronize do
		@sending = nil
		send_flushed.broadcast
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

	rescue DRb::DRbConnError
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

	# Subscribe to +marshalled+. We will be notified of all the modifications
	# that are done to +marshalled+
	def subscribe(marshalled)
	    transmit(:subscribe, marshalled.remote_object) do
		subscriptions << marshalled.remote_object
	    end
	end

	# True if we are subscribed to +remote_object+
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

