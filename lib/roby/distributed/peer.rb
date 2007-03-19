require 'set'
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
	local_only

	argument :peer
	def peer; arguments[:peer] end

	event :ready
	def ready?; event(:ready).happened? end
	def failed(context); end # Peer#connection_listener checks if 'failed' is pending to initiate the disconnection
	event :failed, :terminal => true

	interruptible
    end
    class LiveConnectionTask < Roby::Task
	local_only
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
	    objects.delete_if do |o| 
		o.plan != Roby::Distributed.state.plan ||
		    !o.distribute? ||
		    !o.self_owned?
	    end

	    # If +object+ is a trigger, send the :triggered event but do *not*
	    # act as if +object+ was subscribed
	    peers.each_value do |peer|
		peer.local.trigger(*objects)
	    end
	end
	# Remove +objects+ from the sets of already-triggered objects
	def clean_triggered(object)
	    peers.each_value do |peer|
		peer.local.triggers.each_value do |_, triggered|
		    triggered.delete object
		end
	    end
	end

    end

    class PeerServer
	include DRbUndumped

	# The Peer object we are associated to
	attr_reader :peer

	attr_reader :triggers

	def initialize(peer)
	    @peer	    = peer 
	    @triggers	    = Hash.new
	end

	def to_s; "PeerServer:#{remote_name}" end

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
	def query_result_set(query)
	    plan.query_result_set(peer.local_object(query)).
		delete_if { |obj| !obj.distribute? }
	end

	# The peers asks to be notified if a plan object which matches
	# +matcher+ changes
	def add_trigger(id, matcher)
	    triggers[id] = [matcher, (triggered = ValueSet.new)]
	    Roby.info "#{remote_name} wants notification on #{matcher} (#{id})"

	    Roby::Control.once do
		matcher.each(plan) do |task|
		    if !triggered.include?(task)
			triggered << task
			peer.transmit(:triggered, id, task)
		    end
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

	# Send the neighborhood of +distance+ hops around +object+ to the peer
	def discover_neighborhood(object, distance)
	    object = peer.local_object(object)
	    edges = object.neighborhood(distance)
	    if object.respond_to?(:each_plan_child)
		object.each_plan_child do |plan_child|
		    edges += plan_child.neighborhood(distance)
		end
	    end

	    # Replace the relation graphs by their name
	    edges.delete_if do |rel, from, to, info|
		!(rel.distribute? && from.distribute? && to.distribute?)
	    end
	    edges
	end

	# Called by the remote peer to finalize the three-way handshake
	def connected; peer.connected end
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
	# The set of proxies we are currently removing. See BasicObject#forget_peer
	attr_reader :removing_proxies

	def to_s; "Peer:#{remote_name}" end
	def incremental_dump?(object); false end

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
			peer.tuple = entry
			peer.remote_server.connected
			peer.connected
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
		else 
		    Roby::Distributed.info "#{peer} is already disconnecting"
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
	    @removing_proxies = Hash.new { |h, k| h[k] = Array.new }
	    @mutex	  = Mutex.new
	    @send_flushed = ConditionVariable.new
	    @condition_variables = [ConditionVariable.new]
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
	    local_tasks = Roby::Control.synchronize do
		result_set.map do |task|
		    task = local_object(task)
		    Roby::Distributed.keep[task] += 1
		    task
		end
	    end

	    local_tasks.each do |task|
		yield(task)
	    end

	ensure
	    Roby::Control.synchronize do
		if local_tasks
		    local_tasks.each do |task|
			if (Roby::Distributed.keep[task] -= 1) == 0
			    Roby::Distributed.keep.delete(task)
			end
		    end
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
	    transmit(:add_trigger, matcher.object_id, matcher)
	end

	# Remove a trigger from its ID. +id+ is the return value of Peer#on
	def remove_trigger(id)
	    transmit(:remove_trigger, id)
	    triggers.delete(id)
	end

	# Calls the block given to Peer#on when +task+ has matched the trigger
	def triggered(id, task) # :nodoc:
	    return unless task = local_object(task)
	    Roby::Distributed.keep[task] += 1
	    Roby::Control.once do
		begin
		    if trigger = triggers[id]
			trigger.last.call(task)
		    end
		ensure
		    if (Roby::Distributed.keep[task] -= 1) == 0
			Roby::Distributed.keep.delete(task)
		    end
		end
	    end
	end

	attr_reader :connection_state

	# Initiates a connection with this peer. This inserts a new
	# ConnectionTask task in the plan and starts it. When the connection is
	# complete (the peer has finalized the handshake), the 'ready' event of
	# this task is emitted.
	def connect
	    raise "already connecting" if connecting?
	    raise "already connected" unless disconnected?

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

	    @send_queue = CommunicationQueue.new
	    @send_thread = Thread.new(&method(:communication_loop))

	    Roby::Control.once { task.emit(:ready) }
	    Roby::Distributed.info "connected to #{self}"
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
	    Roby::Distributed.info "failed to ping #{remote_name}: #{e.message}"
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
	    Roby::Distributed.info "disconnecting from #{self}"
	    @connection_state = :disconnecting

	    @send_queue.clear
	    @send_queue.push(nil)
	    unless Thread.current == @send_thread
		@send_thread.join
	    end
	    @send_thread = nil

	    # Remove the keepalive tuple we wrote on the remote host
	    if keepalive
		keepalive.cancel rescue Rinda::RequestExpiredError
	    end

	    # Unsubscribe to the remote plan if we are subscribed to it
	    unsubscribe_plan if remote_plan
	    proxies.dup.each_value do |obj|
		obj.forget_peer(self)
	    end
	    proxies.clear
	    removing_proxies.clear
	end

	# Called when the peer acknowledged the fact that we disconnected
	def disconnected # :nodoc:
	    raise "not disconnecting (#{connection_state})" unless connecting? || disconnecting?
	    @connection_state = nil

	    # Force some cleanup
	    proxies.each_value do |obj|
		obj.remote_siblings.delete(self)
	    end
	    proxies.clear
	    removing_proxies.clear

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
	    else object.sibling_on(self)
	    end
	end
	
	# Returns the local object for +object+. +object+ can be either a
	# marshalled object or a local proxy. Raises ArgumentError if it is
	# none of the two. In the latter case, a RemotePeerMismatch exception
	# is raised if the local proxy is not known to this peer.
	def local_object(object, create = true)
	    if object.kind_of?(DRbObject)
		if local_proxy = proxies[object]
		    proxy_setup(local_proxy)
		    return local_proxy
		end
		raise ArgumentError, "got a DRbObject which has no proxy"
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
		if local_proxy = proxies[object]
		    proxy_setup(local_proxy)
		    return [object, local_proxy]
		end
		raise ArgumentError, "got a DRbObject"
	    elsif object.respond_to?(:proxy)
		[object.remote_object, proxy(object, create_local)]
	    else
		[object.sibling_on(self), object]
	    end
	end

	def proxy_setup(local_object)
	    if !local_object.kind_of?(Roby::Transactions::Proxy) && 
		local_object.respond_to?(:execution_agent) && 
		local_object.plan then

		if !local_object.execution_agent
		    connection_task = local_object.plan[self.task]
		    Roby::Distributed.update_all([local_object, connection_task]) do
			local_object.executed_by connection_task
		    end
		end
	    end
	end

	# Get a proxy for a task or an event. 	
	def proxy(marshalled, create = true)
	    return marshalled unless proxying?(marshalled)
	    if marshalled.respond_to?(:remote_object)
		remote_object = marshalled.remote_object
		return remote_object unless remote_object.kind_of?(DRbObject)
		unless local_object = proxies[remote_object]
		    return if !create
		    return unless local_object = marshalled.proxy(self)
		end
		if marshalled.respond_to?(:update)
		    Roby::Distributed.update(local_object) do
			marshalled.update(self, local_object) 
		    end
		end
		proxy_setup(local_object)
	    else
		local_object = marshalled.proxy(self)
	    end

	    local_object
	end

	# Discovers all objects at a distance +dist+ from +obj+. The object
	# can be either a remote proxy or the remote object itself
	def discover_neighborhood(object, distance)
	    objects = ValueSet.new
	    synchronize do
		synchro_call = get_condvar
		transmit(:discover_neighborhood, object, distance) do |edges|
		    Roby::Control.synchronize do
			edges = local_object(edges)
			edges.each do |rel, from, to, info|
			    objects << from.root_object << to.root_object
			end
			Roby::Distributed.update_all(objects) do
			    edges.each do |rel, from, to, info|
				from.add_child_object(to, rel, info)
			    end
			end

			objects.each do |obj|
			    obj.plan.permanent(obj) unless obj.subscribed?
			end
		    end
		    synchro_call.broadcast
		end
		synchro_call.wait(mutex)
		return_condvar synchro_call
	    end

	    yield(local_object(remote_object(object)))

	    Roby::Control.synchronize do
		objects.each do |obj|
		    obj.plan.auto(obj) unless obj.subscribed?
		end
	    end
	end
    end
end

require 'roby/distributed/subscription'

