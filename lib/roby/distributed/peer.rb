require 'set'
require 'utilrb/array/to_s'
require 'utilrb/socket/tcp_socket'

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
	    peer.disconnected!
	end
	forward :aborted => :failed

	event :failed, :terminal => true do |context| 
	    peer.disconnect
	end
	interruptible
    end

    # Base class for all communication errors
    class ConnectionError   < RuntimeError; end
    # Raised when a connection attempt has failed
    class ConnectionFailedError < RuntimeError
	def initialize(peer); @peer = peer end
    end
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
		peer.local_server.trigger(*objects)
	    end
	end
	# Remove +objects+ from the sets of already-triggered objects
	def clean_triggered(object)
	    peers.each_value do |peer|
		peer.local_server.triggers.each_value do |_, triggered|
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

    end

    class Peer
	include DRbUndumped

	# The local ConnectionSpace object we act on
	attr_reader :connection_space
	# The local PeerServer object for this peer
	attr_reader :local_server
	# The set of proxies for object from this remote peer
	attr_reader :proxies
	# The set of proxies we are currently removing. See BasicObject#forget_peer
	attr_reader :removing_proxies
	# The connection socket with our peer
	attr_reader :socket

	ComStats = Struct.new :rx, :tx
	# A ComStats object which holds the communication statistics for this peer
	# stats.tx is the count of bytes sent to the peer while stats.rx is the
	# count of bytes received
	attr_reader :stats

	def to_s; "Peer:#{remote_name}" end
	def incremental_dump?(object)
	    object.respond_to?(:remote_siblings) && object.remote_siblings[self] 
	end

	# The object which identifies this peer on the network
	attr_reader :remote_id
	# The name of the remote peer
	attr_reader :remote_name
	# The [host, port] pair at the peer end
	attr_reader :peer_info

	# The name of the local ConnectionSpace object we are acting on
	def local_name; connection_space.name end

	# The ID => block hash of all triggers we have defined on the remote plan
	attr_reader :triggers
	# The remote state
	attr_accessor :state

	# Creates a Peer object for the peer connected at +socket+. This peer
	# is to be managed by +connection_space+ If a block is given, it is
	# called in the control thread when the connection is finalized
	def initialize(connection_space, socket, &block)
	    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

	    # Initialize the remote name with the socket parameters. It will be set to 
	    # the real name during the connection process
	    @remote_name = "#{socket.peer_addr}:#{socket.peer_port}"
	    @peer_info = socket.peer_info

	    connection_space.synchronize do
		Roby::Distributed.debug "#{socket} is handled by 0x#{self.address.to_s(16)}"
	    end
	    super() if defined? super

	    @connection_space = connection_space
	    @local_server = PeerServer.new(self)
	    @proxies	  = Hash.new
	    @removing_proxies = Hash.new
	    @mutex	  = Mutex.new
	    @triggers     = Hash.new
	    @socket       = socket
	    @stats        = ComStats.new 0, 0
	    connection_space.pending_sockets << [socket, self]

	    @connection_state = :connecting
	    @send_queue       = Queue.new
	    @completion_queue = Queue.new
	    @current_cycle    = Array.new

	    @task = ConnectionTask.new :peer => self
	    task.on(:ready) { yield(self) } if block_given?
	    Roby::Control.once do
		connection_space.plan.permanent(task)
		task.start!
	    end

	    @send_thread      = Thread.new(&method(:communication_loop))
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
	    call(:query_result_set, query)
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

	# Calls the block given to Peer#on in a separate thread when +task+ has
	# matched the trigger
	def triggered(id, task) # :nodoc:
	    task = local_object(task)
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
		# 1/ try any local RemoteID reference registered in the marshalled object
		local_id  = marshalled.remote_siblings[Roby::Distributed.droby_dump]
		if local_id
		    local_object = local_id.local_object rescue nil
		    local_object = nil if local_object.finalized?
		end

		# 2/ try the #proxies hash
		if !local_object 
		    remote_id = marshalled.remote_siblings[droby_dump]
		    unless local_object = proxies[remote_id]
			return if !create

			# remove any local ID since we are re-creating it
			marshalled.remote_siblings.delete(Roby::Distributed.droby_dump)
			local_object = marshalled.proxy(self)
		    end
		end

		if !local_object
		    raise "no remote siblings for #{remote_name} in #{marshalled} (#{marshalled.remote_siblings})"
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
	alias proxy local_object

	# Discovers all objects at a distance +dist+ from +obj+. The object
	# can be either a remote proxy or the remote object itself
	def discover_neighborhood(object, distance)
	    objects = ValueSet.new
	    Roby.condition_variable(true) do |synchro, mutex|
		mutex.synchronize do
		    transmit(:discover_neighborhood, object, distance) do |edges|
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
			
			synchro.broadcast
		    end
		    synchro.wait(mutex)
		end
	    end

	    yield(local_object(remote_object(object)))

	    Roby::Control.synchronize do
		objects.each { |obj| Roby::Distributed.keep.deref(obj) }
	    end
	end
    end
end

require 'roby/distributed/subscription'

