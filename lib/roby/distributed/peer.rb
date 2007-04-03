require 'set'
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

	event :aborted, :terminal => true do |context|
	    peer.synchronize do
		peer.disconnected!
	    end
	end
	forward :aborted => :failed

	event :failed, :terminal => true do |context| 
	    peer.disconnect
	end
	interruptible
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
	    return if objects.empty?

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

	# Called by our peer when it successfully processed the connection
	# request
	def connect(name, remote_id, remote_server, state)
	    peer.remote_server = remote_server
	    peer.queue_call false, :connected, [Roby::State]
	    peer.synchronize do
		peer.connected
	    end
	    state_update state
	    nil
	end

	def connected(state)
	    peer.synchronize do
		peer.connected
	    end
	    state_update(state)
	    nil
	end

	# Called by our peer when it disconnects
	def disconnected(finalize = true)
	    peer.synchronize do
		if peer.disconnecting?
		    Roby::Control.once do
			peer.remote_server.disconnected(false) if finalize
			peer.synchronize do
			    peer.disconnected
			end
		    end
		else
		    peer.do_disconnect
		end
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
	# The server object we use to access the remote plan database
	attr_accessor :remote_server
	# The neighbour object describing our peer
	attr_reader :neighbour
	# The set of proxies for object from this remote peer
	attr_reader :proxies
	# The set of proxies we are currently removing. See BasicObject#forget_peer
	attr_reader :removing_proxies

	def to_s; "Peer:#{remote_name}" end
	def incremental_dump?(object)
	    object.respond_to?(:remote_siblings) && object.remote_siblings[self] 
	end

	# The object which identifies this peer on the network
	def remote_id; neighbour.remote_id end

	# The name of the remote peer
	def remote_name; neighbour.name end
	# The name of the local ConnectionSpace object we are acting on
	def local_name; connection_space.name end

	# The ID => block hash of all triggers we have defined on the remote plan
	attr_reader :triggers

	# The remote state
	attr_accessor :state

	# Creates a Peer object for +neighbour+, which is managed by
	# +connection_space+.  If a block is given, it is called in the control
	# thread when the connection is finalized
	def initialize(connection_space, neighbour, remote_server = nil, &block)
	    if Roby::Distributed.peers[neighbour.remote_id]
		raise ArgumentError, "there is already a peer for #{neighbour.name}"
	    end
	    super() if defined? super

	    @connection_space = connection_space
	    @neighbour	  = neighbour
	    @local        = PeerServer.new(self)
	    @proxies	  = Hash.new
	    @removing_proxies = Hash.new
	    @mutex	  = Mutex.new
	    @send_flushed = ConditionVariable.new
	    @condition_variables = [ConditionVariable.new]
	    @triggers      = Hash.new
	    @remote_server = remote_server

	    @synchro_point_mutex = Mutex.new
	    @synchro_point_done = ConditionVariable.new

	    Roby::Distributed.peers[remote_id] = self

	    connect(&block)
	end

	class << self
	    private :new
	end

	def self.initiate_connection(connection_space, neighbour, &block)
	    new(connection_space, neighbour, &block)
	end

	def self.connection_request(connection_space, neighbour, remote_server)
	    new(connection_space, neighbour, remote_server)
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
		    Roby::Distributed.keep.ref(task)
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
			Roby::Distributed.keep.deref(task)
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
	    Roby::Distributed.keep.ref(task)
	    Thread.new do
		begin
		    if trigger = triggers[id]
			trigger.last.call(task)
		    end
		rescue Exception
		    Roby.warn "trigger handler #{trigger.last} failed with #{$!.full_message}"
		ensure
		    Roby::Distributed.keep.deref(task)
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
	    @send_queue       = CommunicationQueue.new
	    @completion_queue = CommunicationQueue.new
	    @send_thread      = Thread.new(&method(:communication_loop))

	    @task = ConnectionTask.new :peer => self
	    task.on(:ready) { yield(self) } if block_given?
	    Roby::Control.once do
		connection_space.plan.permanent(task)
		task.emit(:start)
	    end
	    
	    Roby::Distributed.info "connecting to #{remote_name}"
	    if remote_server
		transmit(:connect, connection_space.name, connection_space.remote_id, @local, Roby::State)
	    else
		remote_id.to_drb_object.connect(connection_space.name, connection_space.remote_id, @local)
	    end
	end

	# Called when the handshake is finished. After this call, the
	# connection task has emitted its 'ready' event and the connection is
	# alive
	def connected # :nodoc:
	    Roby::Control.synchronize do
		raise "state is #{@connection_state}, not connecting" unless connecting?
		@connection_state = :connected
	    end

	    Roby::Control.once { task.emit(:ready) }
	    Roby::Distributed.info "connected to #{self}"
	end

	# Normal disconnection procedure. 
	#
	# The procedure is as follows:
	# * we set the connection state as 'disconnecting'. This disables all
	#   notifications for this peer (see for instance
	#   Distributed.each_subscribed_peer)
	# * we queue the :disconnected message
	#
	# At this point, we are waiting for the remote peer to do the same:
	# send us 'disconnected'. When we receive that message, we put the
	# connection into the disconnected state and all transmission is
	# forbidden. We make the transmission thread quit then, and the
	# 'failed' event is emitted on the ConnectionTask task
	#
	# Note that once the connection leaves the connected state, the only
	# messages allowed by #queue_call are 'completed' and 'disconnected'
	def disconnect
	    synchronize { do_disconnect }
	end

	def do_disconnect # :nodoc:
	    raise "already disconnecting" if disconnecting?
	    Roby::Control.synchronize do
		Roby::Distributed.info "disconnecting from #{self}"
		@connection_state = :disconnecting
	    end

	    transmit :disconnected
	end

	# Called when the peer acknowledged the fact that we disconnected
	def disconnected(event = :failed) # :nodoc:
	    Roby::Control.synchronize do
		raise "state is #{@connection_state}, not disconnecting" unless connecting? || disconnecting?
		@connection_state = nil

		if @send_thread && @send_thread != Thread.current
		    begin
			@send_queue.clear
			@send_queue.push nil
			mutex.unlock
			@send_thread.join
		    ensure
			mutex.lock
		    end
		end
		@send_thread = nil
	    end

	    Roby::Control.once do
		task.emit(event)

		proxies.each_value do |obj|
		    obj.remote_siblings.delete(self)
		end
		proxies.clear
	    end
	    removing_proxies.clear

	    connection_space.synchronize do
		Roby::Distributed.peers.delete(remote_id)
	    end
	    Roby::Distributed.info "#{neighbour.name} disconnected"
	end

	# Call to disconnect outside of the normal protocol.
	def disconnected!
	    @connection_state = :disconnecting
	    disconnected(:aborted)
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
	    return false unless connection_space.neighbours.find { |n| n.remote_id == neighbour.remote_id }
	    true
	end

	# Returns true if this peer owns +object+
	def owns?(object); object.owners.include?(self) end

	# Returns the remote object for +object+. +object+ can be either a
	# DRbObject, a marshalled object or a local proxy. In the latter case,
	# a RemotePeerMismatch exception is raised if the local proxy is not
	# known to this peer.
	def remote_object(object)
	    if object.kind_of?(RemoteID)
		object
	    else object.sibling_on(self)
	    end
	end
	
	# Returns the remote_object, local_object pair for +object+. +object+
	# can be either a marshalled object or a local proxy. Raises
	# ArgumentError if it is none of the two. In the latter case, a
	# RemotePeerMismatch exception is raised if the local proxy is not
	# known to this peer.
	def objects(object, create_local = true)
	    if object.kind_of?(RemoteID)
		if local_proxy = proxies[object]
		    proxy_setup(local_proxy)
		    return [object, local_proxy]
		end
		raise ArgumentError, "got a RemoteID which has no proxy"
	    elsif object.respond_to?(:proxy)
		[object.remote_object, proxy(object, create_local)]
	    else
		[object.sibling_on(self), object]
	    end
	end

	def proxy_setup(local_object)
	    if local_object.respond_to?(:execution_agent) && 
		local_object.owners.size == 1 && 
		owns?(local_object) &&
		!local_object.execution_agent &&
		local_object.plan

		remote_owner = local_object.owners.first
		connection_task = local_object.plan[self.task]

		Roby::Distributed.update_all([local_object, connection_task]) do
		    local_object.executed_by connection_task
		end
	    end

	    local_object
	end

	# Returns the local object for +object+. +object+ can be either a
	# marshalled object or a local proxy. Raises ArgumentError if it is
	# none of the two. In the latter case, a RemotePeerMismatch exception
	# is raised if the local proxy is not known to this peer.
	def local_object(marshalled, create = true)
	    if marshalled.kind_of?(RemoteID)
		return marshalled.to_local(self, create)
	    elsif !marshalled.respond_to?(:proxy)
		return marshalled
	    elsif marshalled.respond_to?(:remote_siblings)
		if remote_object = marshalled.remote_siblings[droby_dump]
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
		    raise "no remote siblings for #{remote_name} in #{marshalled} (#{marshalled.remote_siblings})"
		end
	    else
		local_object = marshalled.proxy(self)
	    end

	    local_object
	end
	alias proxy local_object

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

			objects.each { |obj| Roby::Distributed.keep.ref(obj) }
		    end
		    synchro_call.broadcast
		end
		synchro_call.wait(mutex)
		return_condvar synchro_call
	    end

	    yield(local_object(remote_object(object)))

	    Roby::Control.synchronize do
		objects.each { |obj| Roby::Distributed.keep.deref(obj) }
	    end
	end
    end
end

require 'roby/distributed/subscription'

