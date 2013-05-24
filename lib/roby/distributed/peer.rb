require 'set'
require 'utilrb/array/to_s'
require 'utilrb/socket/tcp_socket'

module Roby
    class ExecutionEngine; include DRbUndumped end
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
	event :ready

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
        # This method will call PeerServer#trigger on all peers, for the
        # objects in +objects+ which are eligible for triggering.
        #
        # The same task cannot match the same trigger twice. To allow that,
        # call #clean_triggered.
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
        # Remove +objects+ from the sets of already-triggered objects. So, next
        # time +object+ will be tested for triggers, it will re-match the
        # triggers it has already matched.
	def clean_triggered(object)
	    peers.each_value do |peer|
		peer.local_server.triggers.each_value do |_, triggered|
		    triggered.delete object
		end
	    end
	end
    end

    # PeerServer objects are the objects which act as servers for the plan
    # managers we are connected on, i.e. it will process the messages sent by
    # those remote plan managers.
    #
    # The client part, that is the part which actually send the messages, is
    # a Peer object accessible through the Peer#peer attribute.
    class PeerServer
	include DRbUndumped

	# The Peer object we are associated to
	attr_reader :peer

        # The set of triggers our peer has added to our plan
	attr_reader :triggers

        # Create a PeerServer object for the given peer
	def initialize(peer)
	    @peer	    = peer 
	    @triggers	    = Hash.new
	end

	def to_s # :nodoc:
            "PeerServer:#{remote_name}" 
        end

        # Activate any trigger that may exist on +objects+
        # It sends the PeerServer#triggered message for each objects that are
        # actually matching a registered trigger.
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
	    Roby::Distributed.info "#{remote_name} wants notification on #{matcher} (#{id})"

	    peer.queueing do
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
	    Roby::Distributed.info "#{remote_name} removed #{id} notification"
	    triggers.delete(id)
	    nil
	end

        # Message received when +task+ has matched the trigger referenced by +id+
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

    # This object manages the RemoteID sent by the remote peers, making sure
    # that there is at most one proxy task locally for each ID received
    class RemoteObjectManager
        # The main plan managed by this plan manager. Main plans are mapped to
        # one another across dRoby connections
        attr_reader :plan
	# The set of proxies for object from this remote peer
	attr_reader :proxies
	# The set of proxies we are currently removing. See BasicObject#forget_peer
	attr_reader :removing_proxies
        # This method is used by Distributed.format to determine the dumping
        # policy for +object+. If the method returns true, then only the
        # RemoteID object of +object+ will be sent to the peer. Otherwise,
        # an intermediate object describing +object+ is sent.
	def incremental_dump?(object)
	    object.respond_to?(:remote_siblings) && object.remote_siblings[self] 
	end

        # If true, the manager will use the remote_siblings hash in the
        # marshalled data to determine which proxy #local_object should return.
        #
        # If false, it won't
        #
        # It is true by default. Only logging needs to disable it as the logger
        # is not a dRoby peer
        attr_predicate :use_local_sibling?, true

        def initialize(plan)
            @plan = plan
	    @proxies	  = Hash.new
	    @removing_proxies = Hash.new { |h, k| h[k] = Array.new }
            @use_local_sibling = true
        end

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
		[object.remote_object, local_object(object, create_local)]
	    else
		[object.sibling_on(self), object]
	    end
	end

	def proxy_setup(local_object)
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
		if use_local_sibling? && local_id
		    local_object = local_id.local_object rescue nil
		    local_object = nil if local_object.finalized?
		end

		# 2/ try the #proxies hash
		if !local_object 
                    marshalled.remote_siblings.each_value do |remote_id|
                        if local_object = proxies[remote_id]
                            break
                        end
                    end

                    if !local_object
			if !create
                            return
                        end

			# remove any local ID since we are re-creating it
                        if use_local_sibling?
                            marshalled.remote_siblings.delete(Roby::Distributed.droby_dump)
                        end
			local_object = marshalled.proxy(self)

                        # NOTE: the proxies[] hash is updated by the BasicObject
                        # and BasicObject::DRoby classes, mostly in #update()
                        #
                        # This is so as we have to distinguish between "register
                        # proxy locally" (#add_sibling_for) and "register proxy
                        # locally and announce it to our peer" (#sibling_of)
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

        # Copies the state of this object manager, using +mappings+ to convert
        # the local objects
        #
        # If mappings is not given, an identity is used
        def copy_to(other_manager, mappings = nil)
            mappings ||= Hash.new { |h, k| k }
            proxies.each do |sibling, local_object|
                if mappings.has_key?(local_object)
                    other_manager.proxies[sibling] = mappings[local_object]
                end
            end
        end

        # Returns a new local model named +name+ created by this remote object
        # manager
        #
        # This is used to customize the anonymous model building process based
        # on the RemoteObjectManager instance that is being provided
        def local_model(parent_model, name)
            Roby::Distributed::DRobyModel.anon_model_factory(parent_model, name)
        end

        # Returns a new local task tag named +name+ created by this remote
        # object manager
        #
        # This is used to customize the anonymous task tag building process
        # based on the RemoteObjectManager instance that is being provided
        def local_task_tag(name)
            Roby::Models::TaskServiceModel::DRoby.anon_tag_factory(name)
        end

        # Called when +remote_object+ is a sibling that should be "forgotten"
        #
        # It is usually called by Roby::BasicObject#remove_sibling_for
        def removed_sibling(remote_object)
            if remote_object.respond_to?(:remote_siblings)
                remote_object.remote_siblings.each_value do |remote_id|
                    proxies.delete(remote_id)
                end
            else
                proxies.delete(remote_object)
            end
        end

        def clear
            proxies.clear
            removing_proxies.clear
        end
    end

    # A Peer object is the client part of a connection with a remote plan
    # manager. The server part, i.e. the object which actually receives
    # requests from the remote plan manager, is the PeerServer object
    # accessible through the Peer#local_server attribute.
    #
    # == Connection procedure
    #
    # Connections are initiated When the user calls Peer.initiate_connection.
    # The following protocol is then followed:
    # [local] 
    #   if the neighbour is already connected to us, we do nothing and yield
    #   the already existing peer. End.
    # [local]
    #   check if we are already connecting to the peer. If it is the case,
    #   wait for the end of the connection thread.
    # [local] 
    #   otherwise, open a new socket and send the connect() message in it
    #   The connection thread is registered in ConnectionSpace.pending_connections
    # [remote] 
    #   check if we are already connecting to the peer (check ConnectionSpace.pending_connections)
    #   * if it is the case, the lowest token wins
    #   * if 'remote' wins, return :already_connecting
    #   * if 'local' wins, return :connected with the relevant information
    #
    # == Communication
    #
    # Communication is done in two threads. The sending thread gets the calls
    # from Peer#send_queue, formats them and sends them to the PeerServer#demux
    # for processing. The reception thread is managed by dRb and its entry
    # point is always #demux.
    #
    # Very often we need to have processing on both sides to finish an
    # operation. For instance, the creation of two siblings need to register
    # the siblings on both sides. To manage that, it is possible for PeerServer
    # methods which are serving a remote request to queue callbacks.  These
    # callbacks will be processed by Peer#send_thread before the rest of the
    # queue might be processed
    class Peer < RemoteObjectManager
	include DRbUndumped

	# The local ConnectionSpace object we act on
	attr_reader :connection_space
	# The local PeerServer object for this peer
	attr_reader :local_server
	# The connection socket with our peer
	attr_reader :socket

	ComStats = Struct.new :rx, :tx
	# A ComStats object which holds the communication statistics for this peer
	# stats.tx is the count of bytes sent to the peer while stats.rx is the
	# count of bytes received
	attr_reader :stats

	def to_s # :nodoc:
            "Peer:#{remote_name}" 
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

        # The plan associated to our connection space
        def plan; connection_space.plan end
        # The execution engine associated to #plan
        def engine; connection_space.plan.engine end

	# Creates a Peer object for the peer connected at +socket+. This peer
	# is to be managed by +connection_space+ If a block is given, it is
	# called in the control thread when the connection is finalized
	def initialize(connection_space, socket, remote_name, remote_id, remote_state, &block)
	    # Initialize the remote name with the socket parameters. It will be set to 
	    # the real name during the connection process
	    @remote_name = remote_name
	    @remote_id   = remote_id
	    @peer_info   = socket.peer_info

	    super() if defined? super

	    @connection_space = connection_space
	    @local_server = PeerServer.new(self)
	    @mutex	  = Mutex.new
	    @triggers     = Hash.new
	    @socket       = socket
	    @stats        = ComStats.new 0, 0
	    @dead	  = false
	    @disabled_rx  = 0
	    @disabled_tx  = 0
	    connection_space.pending_sockets << [socket, self]

	    @connection_state = :connected
	    @send_queue       = Queue.new
	    @completion_queue = Queue.new
	    @current_cycle    = Array.new

	    Roby::Distributed.peers[remote_id]   = self
	    local_server.state_update remote_state

	    @task = ConnectionTask.new :peer => self
	    connection_space.plan.engine.once do
		connection_space.plan.add_permanent(task)
		task.start!
		task.emit(:ready)
	    end

	    @send_thread      = Thread.new(&method(:communication_loop))
	end

	# The peer name
	attr_reader :name
	# The ConnectionTask object for this peer
	attr_reader :task

	# Creates a query object on the remote plan. 
        #
        # For thread-safe operation, always use #each on the resulting query:
        # during the enumeration, the local plan GC will not remove those
        # tasks.
	def find_tasks
	    Roby::Queries::Query.new(self)
	end

        def removed_sibling(remote_object)
            super
            subscriptions.delete(remote_object)
        end

        # Returns a set of remote tasks for +query+ applied on the remote plan
        # This is not to be accessed directly. It is part of the Query
        # interface.
        #
        # See #find_tasks.
	def query_result_set(query)
	    result = ValueSet.new
	    call(:query_result_set, query) do |marshalled_set|
		for task in marshalled_set
		    task = local_object(task)
		    Roby::Distributed.keep.ref(task)
		    result << task
		end
	    end

	    result
	end
	
        # Yields the tasks saved in +result_set+ by #query_result_set.  During
        # the enumeration, the tasks are marked as permanent to avoid plan GC.
        # The block can subscribe to the one that are interesting. After the
        # block has returned, all non-subscribed tasks will be subject to plan
        # GC.
	def query_each(result_set) # :nodoc:
	    result_set.each do |task|
		yield(task)
	    end

	ensure
	    Roby.synchronize do
		if result_set
		    result_set.each do |task|
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
        #
        # This sends the PeerServer#add_trigger message to the peer.
	def on(matcher, &block)
	    triggers[matcher.object_id] = [matcher, block]
	    transmit(:add_trigger, matcher.object_id, matcher)
	end

        # Remove a trigger referenced by its ID. +id+ is the value returned by
        # Peer#on
        #
        # This sends the PeerServer#remove_trigger message to the peer.
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
		    Roby::Distributed.warn "trigger handler #{trigger.last} failed with #{$!.full_message}"
		ensure
		    Roby::Distributed.keep.deref(task)
		end
	    end
	end

	# Returns true if this peer owns +object+
	def owns?(object); object.owners.include?(self) end

	# Discovers all objects at a distance +dist+ from +obj+. The object
	# can be either a remote proxy or the remote object itself
	def discover_neighborhood(object, distance)
	    objects = ValueSet.new
	    Roby.condition_variable(true) do |synchro, mutex|
		mutex.synchronize do
                    done = false
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
			
                        done = true
			synchro.broadcast
		    end
                    while !done
                        synchro.wait(mutex)
                    end
		end
	    end

	    yield(local_object(remote_object(object)))

	    Roby.synchronize do
		objects.each { |obj| Roby::Distributed.keep.deref(obj) }
	    end
	end
    end
end

require 'roby/distributed/subscription'

