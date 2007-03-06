require 'set'
require 'utilrb/queue'
require 'utilrb/array/to_s'

require 'roby'
require 'roby/state'
require 'roby/planning'
require 'roby/distributed/notifications'
require 'roby/distributed/proxy'
require 'roby/distributed/communication'

class DRbObject
    def to_s
	if __drbref
	    "#<DRbObject ref=0x#{Object.address_from_id(__drbref).to_s(16)} uri=#{__drburi}>"
	else
	    "#<DRbObject ref=nil uri=#{__drburi}>"
	end
    end
    def inspect; to_s end
    def pretty_print(pp); pp.text to_s end
end

module Roby
    class Control; include DRbUndumped end
end

module Roby::Distributed
    class ConnectionSpace
	def add_owner(object, peer)
	    object.add_owner(peer, false)
	end
	def remove_owner(object, peer)
	    object.remove_owner(peer, false)
	end
	def prepare_remove_owner(object, peer)
	    object.prepare_remove_owner(peer)
	rescue Exception => e
	    e
	end
    end

    class ConnectionTask < Roby::Task
	local_object

	argument :peer
	def peer; arguments[:peer] end

	event :ready
	def ready?; event(:ready).happened? end
	def failed(context); end # Peer#connection_listener checks if 'failed' is pending to initiate the disconnection
	event :failed, :terminal => true

	interruptible
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

    class << self
	def trigger(*objects)
	    return unless Roby::Distributed.state 

	    # If +object+ is a trigger, send the :triggered event but do *not*
	    # act as if +object+ was subscribed
	    objects.delete_if { |o| o.plan != Roby::Distributed.state.plan }
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

    end

    class PeerServer
	include DRbUndumped

	# The Peer object we are associated to
	attr_reader :peer

	# The set of objects the remote peer is subscribed to. Unlike for
	# Peer#subscriptions, these are local objects
	attr_reader :subscriptions
	attr_reader :triggers

	def to_s; "PeerServer:#{remote_name}" end

	def initialize(peer)
	    @peer	    = peer 
	    @subscriptions  = ValueSet.new
	    @triggers	    = Hash.new
	end

	# Activate any trigger that may exist on +objects+
	def trigger(*objects)
	    triggers.each do |id, (matcher, triggered)|
		objects.each do |object|
		    next if object.respond_to?(:__getobj__)
		    next unless object.plan
		    next unless object.self_owned? && object.plan.has_sibling?(peer)
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
	def query_result_set(query)
	    plan.query_result_set(peer.local_object(query))
	end

	# The peers asks to be notified if a plan object which matches
	# +matcher+ changes
	def add_trigger(id, matcher)
	    triggers[id] = [matcher, (triggered = ValueSet.new)]
	    Roby.info "#{remote_name} wants notification on #{matcher} (#{id})"

	    Roby::Control.once do
		matcher.each(plan) do |task|
		    triggered << task
		    peer.transmit(:triggered, id, task)
		end
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

	def add_owner(object, new_owner)
	    peer.local_object(object).add_owner(new_owner, false)
	    nil
	end
	def remove_owner(object, new_owner)
	    peer.local_object(object).remove_owner(new_owner, false)
	    nil
	end
	def prepare_remove_owner(object, new_owner)
	    peer.local_object(object).prepare_remove_owner(new_owner)
	    nil
	rescue
	    $!
	end

	# Send the neighborhood of +distance+ hops around +object+ to the peer
	def discover_neighborhood(object, distance)
	    object = peer.local_object(object)
	    edges = object.neighborhood(distance)
	    if object.kind_of?(Roby::Task)
		object.each_event do |obj_ev|
		    edges += obj_ev.neighborhood(distance)
		end
	    end

	    # Replace the relation graphs by their name
	    edges.delete_if do |rel, from, to, info|
		!(rel.distribute? && from.distribute? && to.distribute?)
	    end
	    edges
	end

	# Relations to be sent to the remote host if +object+ is in a plan. The
	# returned array if formatted as [ [graph, graph_edges], [graph, ..] ]
	# where graph_edges is [[parent, child, data], ...]
	def relations_of(object)
	    result = []
	    # For transaction proxies, never send non-discovered relations to
	    # remote hosts
	    Roby::Distributed.each_object_relation(object) do |graph|
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
		    peer.local_object(a)
		else a
		end
	    end.compact
	    if block_given? then yield(args)
	    else args
	    end
	end

	# Receive an update on the relation graphs
	def update_relation(plan, args)
	    if plan
		Roby::Distributed.update([peer.local_object(plan)]) { update_relation(nil, args) }
	    else
		m_from, op, m_to, m_rel, m_info = *args
		from, to = peer.local_object(m_from), 
		    peer.local_object(m_to)
		return if !from || !to

		rel = peer.local_object(m_rel)
		if op == :add_child_object
		    Roby::Distributed.update([from.root_object, to.root_object]) do
			from.add_child_object(to, rel, peer.local_object(m_info))
		    end

		elsif op == :remove_child_object
		    Roby::Distributed.update([from.root_object, to.root_object]) do
			from.remove_child_object(to, rel)
		    end
		end
	    end
	    nil
	end

	# Unmarshalls elements of +args+, gets their proxy, calls
	# Distributed.update and yield
	#
	# If one of the objects should be ignored (Peer#proxy returns nil),
	# the provided block will not get called
	def unmarshall_and_update(args, create = true)
	    updating = ValueSet.new
	    args = [args] unless args.respond_to?(:map)
	    args = args.map do |o|
		if peer.proxying?(o)
		    proxy = peer.local_object(o, create)
		    if !proxy
			return
		    end
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

	def connected
	    peer.connected
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
	# The set of proxies for object from this remote peer
	attr_reader :proxies

	def to_s; "Peer:#{remote_name}" end

	# The object which identifies this peer on the network
	def remote_id; neighbour.tuplespace end

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

	    all_peers = connection_space.tuplespace.
		read_all 'kind' => :peer, 'tuplespace' => nil, 'remote' => nil, 'state' => nil

	    all_peers.each do |entry|
		remote_ts = entry['tuplespace']
		seen << remote_ts
		peer = connection_space.peers[remote_ts]

		if peer
		    next if peer.task.event(:failed).pending?
		    if peer.connecting?
			# The peer finalized the handshake
			peer.connected
			peer.remote_server.connected
		    elsif peer.connected?
			# ping the remote host
			peer.ping
			# update the host state
			peer.tuple = entry
		    end
		elsif neighbour = connection_space.neighbours.find { |n| n.tuplespace == remote_ts }
		    Roby::Distributed.info "peer #{neighbour.name} asking for connection"
		    Peer.new(connection_space, neighbour)
		end
	    end

	    # Handle the 'failed' event of the connection task
	    Roby::Distributed.peers.dup.each do |remote_id, peer|
		next unless peer.task.event(:failed).pending?
		if peer.connecting?
		    Roby::Distributed.info "aborting connection handshake with #{peer.remote_name}"
		    peer.disconnected
		elsif peer.connected?
		    Roby::Distributed.info "disconnecting from #{peer.remote_name}"
		    peer.disconnect
		end
	    end

	    (connection_space.peers.keys - seen).each do |disconnected| 
		peer = connection_space.peers[disconnected]
		if peer.connecting?
		    Roby::Distributed.info "waiting for peer #{peer.remote_name} to connect"
		    peer.ping
		elsif peer.connected?
		    Roby::Distributed.info "peer #{peer.remote_name} disconnected"
		    peer.disconnect
		    peer.disconnected
		elsif peer.disconnecting?
		    peer.disconnected
		end
	    end
	end

	# Creates a Peer object for +neighbour+, which is managed by
	# +connection_space+.  If a block is given, it is called in the control
	# thread when the connection is finalized
	def initialize(connection_space, neighbour, &block)
	    if Roby::Distributed.peers[neighbour.tuplespace]
		raise ArgumentError, "there is already a peer for #{neighbour.name}"
	    end
	    super() if defined? super

	    @connection_space = connection_space
	    @neighbour	  = neighbour
	    @local        = PeerServer.new(self)
	    @proxies	  = Hash.new
	    @mutex	  = Mutex.new
	    @send_flushed = ConditionVariable.new
	    @synchro_call = ConditionVariable.new
	    @max_allowed_errors = connection_space.max_allowed_errors
	    @triggers = Hash.new

	    @synchro_point_mutex = Mutex.new
	    @synchro_point_done = ConditionVariable.new

	    Roby::Distributed.peers[remote_id] = self

	    connect(&block)
	end

	# The peer name
	attr_reader :name
	# The ConnectionTask object for this peer
	attr_reader :task

	# Creates a query object on the remote plan
	def find_tasks
	    Roby::Query.new(self)
	end

	# Returns a set of remote tasks for +query+ applied on the remote plan
	def query_result_set(query)
	    remote_server.query_result_set(query)
	end
	
	# Yields the tasks saved in +result_set+ by #query_result_set.  During
	# the enumeration, the tasks are marked as permanent to avoid plan GC.
	# The block can subscribe to the one that are interesting. After the
	# block has returned, all non-subscribed tasks will be subject to plan
	# GC.
	def query_each(result_set)
	    result_set = Roby::Control.synchronize do
		result_set.map do |task|
		    task = local_object(task)
		    task.plan.permanent(task) unless task.subscribed?
		    task
		end
	    end

	    result_set.each do |task|
		yield(task)
	    end

	ensure
	    Roby::Control.synchronize do
		result_set.each do |task|
		    task.plan.auto(task) unless task.subscribed?
		end
	    end
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
	    call(:add_trigger, matcher.object_id, matcher)
	end

	# Remove a trigger from its ID. +id+ is the return value of Peer#on
	def remove_trigger(id)
	    call(:remove_trigger, id)
	    triggers.delete(id)
	end

	# Calls the block given to Peer#on when +task+ has matched the trigger
	def triggered(id, task) # :nodoc:
	    return unless task = local_object(task)
	    if trigger = triggers[id]
		trigger.last.call(task)
	    end
	end

	attr_reader :connection_state

	# Initiates a connection with this peer. This inserts a new
	# ConnectionTask task in the plan and starts it. When the connection is
	# complete (the peer has finalized the handshake), the 'ready' event of
	# this task is emitted.
	def connect
	    raise "already connecting" if connecting?
	    @connection_state = :connecting

	    @task = ConnectionTask.new :peer => self
	    if block_given?
		task.on(:ready) { yield(self) }
	    end

	    Roby::Control.once do
		connection_space.plan.permanent(task)
		task.emit(:start)
	    end
	    ping
	    Roby::Distributed.info "connecting to #{remote_name}"
	end

	# Called when the handshake is finished. After this call, the
	# connection task has emitted its 'ready' event and the connection is
	# alive
	def connected # :nodoc:
	    raise "not connecting" unless connecting?
	    @connection_state = :connected

	    @send_queue = Queue.new
	    @send_thread = Thread.new(&method(:communication_loop))

	    @tuple = connection_space.tuplespace.read(
		    {'kind' => :peer, 'tuplespace' => neighbour.tuplespace, 'remote' => nil, 'state' => nil}, 
		    0)

	    Roby::Control.once { task.emit(:ready) }
	    Roby::Distributed.info { "connected to #{neighbour.name}" }
	end

	# Updates our keepalive token on the peer
	def ping(timeout = nil)
	    raise "neither connected nor connecting" unless connected? || connecting?
	    @dead = false
	    return if !link_alive? 

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
	    disconnected
	end

	# Disconnect this side of the connection. The remote host is supposed
	# to acknowledge that by removing its last keepalive tuple from our
	# connection space.
	#
	# The 'failed' event is emitted on the ConnectionTask task
	def disconnect
	    raise "already disconnecting" if disconnecting?
	    @connection_state = :disconnecting

	    # Remove the keepalive tuple we wrote on the remote host
	    if keepalive
		keepalive.cancel rescue Rinda::RequestExpiredError
	    end

	    proxies.dup.each_key do |obj|
		delete(obj)
	    end
	    proxies.clear

	    @send_queue.push(nil)
	    unless Thread.current == @send_thread
		@send_thread.join
	    end
	    @send_thread = nil
	end

	# Called when the peer acknowledged the fact that we disconnected
	def disconnected # :nodoc:
	    raise "not disconnecting (#{connection_state})" unless connecting? || disconnecting?
	    @connection_state = nil

	    Roby::Distributed.peers.delete(remote_id)

	    Roby::Distributed.info "#{neighbour.name} disconnected"
	    Roby::Control.once { task.emit(:failed) }
	end

	# Call to disconnect outside of the normal protocol.
	def disconnected!
	    # Remove the neighbour tuple ourselves
	    tuplespace.take_all(
		{ 'kind' => :peer, 'tuplespace' => remote_id, 'remote' => nil, 'state' => nil },
		0) rescue nil

	    # ... and let neighbour discovery do the cleanup
	    return unless connecting? || connected?
	    disconnect
	end

	# Returns true if we are establishing a connection with this peer
	def connecting?; connection_state == :connecting end
	# Returns true if the connection has been established. See also #link_alive?
	def connected?; connection_state == :connected end
	# Returns true if the we disconnected on our side but the peer did not
	# acknowledge it yet
	def disconnecting?; connection_state == :disconnecting end
	# Returns true if the connection with this peer has been removed
	def disconnected?; !connection_state end

	# Mark the link as dead regardless of the last neighbour discovery. This
	# will be reset during the next neighbour discovery
	def link_dead!; @dead = true end
	# Checks if the connection is currently alive
	def link_alive?
	    return false if @dead
	    return false unless connection_space.neighbours.find { |n| n.tuplespace == neighbour.tuplespace }
	    true
	end

	# Returns true if this peer owns +object+
	def owns?(object); object.owners.include?(self) end

	# Check if +object+ should be proxied
	def proxying?(marshalled)
	    marshalled.respond_to?(:proxy)
	end

	# Returns the remote object for +object+. +object+ can be either a
	# DRbObject, a marshalled object or a local proxy. In the latter case,
	# a RemotePeerMismatch exception is raised if the local proxy is not
	# known to this peer.
	def remote_object(object)
	    if object.kind_of?(DRbObject)
		object
	    elsif object.respond_to?(:proxy)
		object.remote_object
	    else object.remote_object(self)
	    end
	end
	
	# Returns the local object for +object+. +object+ can be either a
	# marshalled object or a local proxy. Raises ArgumentError if it is
	# none of the two. In the latter case, a RemotePeerMismatch exception
	# is raised if the local proxy is not known to this peer.
	def local_object(object, create = true)
	    if object.kind_of?(DRbObject)
		if local_proxy = @proxies[object]
		    proxy_setup(local_proxy)
		    return local_proxy
		end
		raise ArgumentError, "got a DRbObject which has no proxy yet. Internal problem with incremental updates"
	    elsif object.respond_to?(:proxy)
		proxy(object, create)
	    else object
	    end
	end
	
	# Returns the remote_object, local_object pair for +object+. +object+
	# can be either a marshalled object or a local proxy. Raises
	# ArgumentError if it is none of the two. In the latter case, a
	# RemotePeerMismatch exception is raised if the local proxy is not
	# known to this peer.
	def objects(object, create_local = true)
	    if object.kind_of?(DRbObject)
		if local_proxy = @proxies[object]
		    proxy_setup(local_proxy)
		    return [object, local_proxy]
		end
		raise ArgumentError, "got a DRbObject"
	    elsif object.respond_to?(:proxy)
		[object.remote_object, proxy(object, create_local)]
	    else
		[object.remote_object(self), object]
	    end
	end

	def proxy_setup(object_proxy)
	    if !object_proxy.kind_of?(Roby::Transactions::Proxy) && 
		object_proxy.respond_to?(:execution_agent) && 
		object_proxy.plan then

		if !object_proxy.execution_agent
		    connection_task = object_proxy.plan[self.task]
		    Roby::Distributed.update([object_proxy, connection_task]) do
			object_proxy.executed_by connection_task
		    end
		end
	    end
	end

	# Get a proxy for a task or an event. 	
	def proxy(marshalled, create = true)
	    return marshalled unless proxying?(marshalled)
	    if marshalled.respond_to?(:remote_object)
		object = marshalled.remote_object
		return object unless object.kind_of?(DRbObject)
		unless object_proxy = @proxies[object]
		    return if !create
		    return unless object_proxy = marshalled.proxy(self)
		    @proxies[object] = object_proxy
		end
		if marshalled.respond_to?(:update)
		    Roby::Distributed.update([object_proxy]) do
			marshalled.update(self, object_proxy) 
		    end
		end
		proxy_setup(object_proxy)
	    else
		object_proxy = marshalled.proxy(self)
	    end

	    object_proxy
	end

	# +remote_object+ is not a valid remote object anymore
	def delete(object, remove_object = false)
	    remote_object = self.remote_object(object)
	    subscriptions.delete(remote_object)
	    if local_object = proxies.delete(remote_object)
		local_object.remote_siblings.delete(self)

		case local_object
		when Roby::PlanObject
		    return if !local_object.root_object?
		    if 
			if remove_object
			    connection_space.plan.remove_object(local_object)
			end
			if local_object.root_object? && local_object.plan
			    raise "deleting an object still attached to the plan"
			end
		    end
		end
	    end
	end

	# Discovers all objects at a distance +dist+ from +obj+. The object
	# can be either a remote proxy or the remote object itself
	def discover_neighborhood(object, distance)
	    objects = ValueSet.new

	    synchronize do
		transmit(:discover_neighborhood, object, distance) do |edges|
		    Roby::Control.synchronize do
			edges = local_object(edges)
			edges.each do |rel, from, to, info|
			    objects << from.root_object << to.root_object
			end
			Roby::Distributed.update(objects) do
			    edges.each do |rel, from, to, info|
				from.add_child_object(to, rel, info)
			    end
			end

			objects.each do |obj|
			    obj.plan.permanent(obj) unless subscribed?(obj)
			end
		    end
		    synchro_call.broadcast
		end
		synchro_call.wait(mutex)
	    end

	    yield(proxies[object.remote_object(self)])

	    Roby::Control.synchronize do
		objects.each do |obj|
		    obj.plan.auto(obj) unless subscribed?(obj)
		end
	    end
	end

	# Returns true if +proxy+ is related to a local task
	def linked_to_local?(proxy)
	    Roby::Distributed.each_object_relation(proxy) do |rel|
		if proxy.related_objects(rel).any? { |obj| !obj.kind_of?(RemoteObjectProxy) }
		    return true
		end
	    end
	    false
	end

	def need_updates?(local_object)
	    return true if local.subscribed?(local_object)
	    return true if local_object.has_sibling?(self) && owns?(local_object)

	    if local_object.kind_of?(Roby::PlanObject)
		Roby::Distributed.each_object_relation(local_object) do |rel|
		    local_object.related_objects(rel).each do |related_object| 
			if local.subscribed?(related_object) || 
			    related_object.has_sibling?(self) && owns?(related_object)
			    return true
			end
		    end
		end

		if local_object.respond_to?(:each_plan_child)
		    local_object.each_plan_child do |plan_child|
			return true if need_updates?(plan_child)
		    end
		end
	    end

	    false
	end
    end
end

require 'roby/distributed/subscription'

