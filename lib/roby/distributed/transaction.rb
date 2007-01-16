require 'roby'
require 'roby/distributed/objects'
require 'roby/distributed/proxy'

module Roby
    module Distributed
	class Transaction < Roby::Transaction
	    include DistributedObject

	    attr_reader :owners
	    def initialize(plan, owners = nil)
		@owners = Set.new
		@owners.merge(owners) if owners
		super(plan)
	    end

	    include DistributedObject

	    # Add the Peer +peer+ to the list of owners
	    def add_owner(peer, distributed = true)
		peer_id = if peer.respond_to?(:remote_id) then peer.remote_id
			  else peer
			  end

		return if @owners.include?(peer_id)

		if distributed
		    remote_siblings.each do |_, remote|
			remote.add_owner(peer_id, false)
		    end
		end
		@owners << peer_id
		Roby.debug { "added owner to #{self}: #{owners.to_a}" }
	    end

	    # Checks that +peer_id+ can be removed from the list of owners
	    def prepare_remove_owner(peer_id)
		each_task(true) do |t|
		    if discovered_relations_of?(t) && t.owners.include?(peer_id)
			raise OwnershipError, "#{peer_id} still owns tasks in the transaction (#{t})"
		    end
		end
	    end

	    # Removes +peer+ from the list of owners. Raises OwnershipError if
	    # there are modified tasks in this transaction which are owned by
	    # +peer+
	    def remove_owner(peer, do_check = true)
		peer_id = if peer.respond_to?(:remote_id) then peer.remote_id
			  else peer
			  end

		return unless @owners.include?(peer_id)

		if do_check
		    prepare_remove_owner(peer_id)
		    remote_siblings.each do |_, remote|
			remote.prepare_remove_owner(peer_id)
		    end
		end

		@owners.delete(peer_id)
		remote_siblings.each do |_, remote|
		    remote.remove_owner(peer_id, false)
		end
	    end

	    # Sends the transaction to +peer+. This must be done only once.
	    def propose(peer, &block)
		peer.transaction_propose(self, &block)
	    end

	    def discover(objects)
		if objects
		    events, tasks = partition_event_task(objects)
		    (events + tasks).each do |object|
			if !object.kind_of?(Transactions::Proxy) && !object.owners.subset?(owners)
			    raise NotOwner, "#{object} is not owned by #{owners.to_a} (#{object.owners.to_a})"
			end
		    end
		    super(events)
		    super(tasks)
		else
		    super
		end
	    end

	    def discovered_object(object, relation)
		super if defined? super

	    end

	    # Sends the provided command to all owners. If +ignore_missing+ is
	    # true, ignore the owners to which the transaction has not yet been
	    # proposed. Raises InvalidRemoteOperation if +ignore_missing+.
	    #
	    # Yields the value returned by the remote owners to the block
	    # inside the communication thread. +done+ is true for the last peer
	    # to reply.
	    def apply_to_owners(ignore_missing, *args) # :nodoc:
		if !ignore_missing
		    owners.each do |remote_id|
			if remote_id.kind_of?(DRbObject) && !remote_siblings.has_key?(remote_id)
			    raise InvalidRemoteOperation, "cannot do #{args} if the transaction is not distributed on all its owners"
			end
		    end
		end

		waiting_for = owners.size - 1
		result = Distributed.state.send(*args)
		yield(waiting_for == 0, result) if block_given?

		owners.each do |remote_id| 
		    next unless remote_siblings.include?(remote_id)
		    next unless remote_id.kind_of?(DRbObject)

		    Distributed.peer(remote_id).transmit(*args) do |result|
			waiting_for -= 1
			yield(waiting_for == 0, result) if block_given?
		    end
		end
	    end

	    # call-seq:
	    #   commit_transaction			=> self
	    #   commit_transaction { |done| ... }	=> self
	    #
	    # Commits the transaction. Distributed commit is done in two steps,
	    # to make sure that all owners agree on the transaction commit. 
	    #
	    # Unlike Roby::Transaction#commit_transaction the transaction is
	    # *not* yet committed when the method returns. The provided block
	    # (if any) will be called in the control thread with +result+ to
	    # true if the transaction has been committed, to false if the
	    # commit is being canceled. In the latter case,
	    # #abandoned_commit is called as well.
	    def commit_transaction(synchro = true)
		unless Distributed.owns?(self)
		    raise NotOwner, "cannot commit a transaction which is not owned locally. #{self} is owned by #{owners.to_a}"
		end

		if synchro
		    error = nil
		    apply_to_owners(false, :transaction_prepare_commit, self) do |done, result|
			error ||= result
			if done
			    if error
				apply_to_owners(true, :transaction_abandon_commit, self, error)
				Control.once { yield(self, false) } if block_given?
			    else
				Control.once do
				    apply_to_owners(false, :transaction_commit, self) do |done, _|
					Control.once { yield(self, true) } if block_given? && done
				    end
				end
			    end
			end
		    end
		else
		    proxy_objects = (known_tasks(true) | discovered_objects)
		    plan_objects = proxy_objects.map { |o| may_unwrap(o) }
		    Distributed.update(proxy_objects | plan_objects) do
		       	super()
		    end
		end

		self
	    end

	    # Hook called when the transaction commit has been abandoned
	    # because a owner refused it. +reason+ is the value returned by
	    # this peer.
	    def abandoned_commit(reason)
		Roby.debug { "abandoned commit of #{self} because of #{error}" }
		super if defined? super 
	    end

	    # call-seq:
	    #	discard_transaction	    => self 
	    #
	    # Discards the transaction. Unlike #commit_transaction, this is
	    # done synchronously on the local plan and cannot be canceled by
	    # remote peers
	    def discard_transaction(synchro = true) # :nodoc:
		unless Distributed.owns?(self)
		    raise NotOwner, "cannot discard a transaction which is not owned locally. #{self} is owned by #{owners}"
		end

		if synchro
		    apply_to_owners(true, :transaction_discard, self)
		else super()
		end
		self
	    end

	    # What do we need to do on the remote side ?
	    #   - create a new transaction with the right owners, either on our own plan,
	    #     or even on another shared transaction.
	    #   - create all needed transaction proxys. Transaction proxys
	    #     can apply on local and remote tasks
	    #   - create all needed remote proxys
	    #   - setup all relations
	    
	    # Distributed transactions are marshalled as DRbObjects and #proxy
	    # returns their sibling in the remote pDB (or raises if there is none)
	    class DRoby < Roby::Plan::DRoby # :nodoc:
		def _dump(lvl)
		    Distributed.dump([DRbObject.new(remote_object), plan, owners]) 
		end
		def self._load(str)
		    new(*Marshal.load(str))
		end
		def proxy(peer)
		    unless trsc = peer.find_transaction(remote_object, peer.proxy(plan)) 
			raise InvalidRemoteOperation, "#{remote_object} does not exist on #{peer.connection_space.name}"
		    end
		    trsc
		end

		def to_s; "mdTransaction(#{remote_object.__drbref}/#{plan.remote_object.__drbref})" end

		attr_reader :plan, :owners
		def initialize(remote_object, plan, owners)
		    super(remote_object)
		    @plan, @owners = plan, owners
		end
	    end
	    def droby_dump # :nodoc:
		DRoby.new(self, self.plan, self.owners)
	    end
	end

	class MarshalledRemoteTransactionProxy # :nodoc:
	    def self._load(str)
		MarshalledRemoteTransactionProxy.new(*Marshal.load(str))
	    end
	    def _dump(lvl)
		Distributed.dump([DRbObject.new(remote_object), real_object, transaction])
	    end
	    def proxy(peer)
		return unless local_real = peer.proxy(real_object)
		local_object = peer.proxy(transaction)[local_real]
		if local_object.respond_to?(:remote_siblings)
		    local_object.remote_siblings[peer.remote_id] = remote_object
		end
		local_object
	    end

	    def to_s; "m(rtProxy(#{real_object}))" end

	    attr_reader :remote_object, :real_object, :transaction
	    def initialize(remote_object, real_object, transaction)
		@remote_object, @real_object, @transaction = 
		    remote_object, real_object, transaction 
	    end
	end
	module Roby::Transaction::Proxy
	    def droby_dump # :nodoc:
		MarshalledRemoteTransactionProxy.new(self, @__getobj__, transaction)
	    end
	end
	module RemoteTransactionProxy
	    include DistributedObject
	    def has_sibling?(peer); plan.has_sibling?(peer) end

	    def discover(relation, mark)
		return unless proxying?
		unless !mark || Distributed.updating?([self]) || owners.subset?(plan.owners)
		    raise NotOwner, "transaction owners #{plan.owners.inspect} do not own #{self.to_s}: #{owners.inspect}"
		end

		owners.each do |owner|
		    peer = Distributed.peer(owner)
		    if !peer.subscribed?(remote_object(owner))
			raise "must subscribe to #{self} on #{peer} before changing it"
		    end
		end

		super
	    end
	end

	class TaskTransactionProxy < Roby::Transactions::Task
	    include RemoteTransactionProxy

	    proxy_for Roby::Distributed::TaskProxy
	    def_delegator :@__getobj__, :remote_object
	end
	class EventGeneratorTransactionProxy < Roby::Transactions::EventGenerator
	    include RemoteTransactionProxy

	    proxy_for Roby::Distributed::EventGeneratorProxy
	    def_delegator :@__getobj__, :remote_object
	end

	class PeerServer
	    def transaction_create(remote_trsc)
		if dtrsc = (peer.proxy(remote_trsc) rescue nil)
		    raise ArgumentError, "#{remote_trsc} is already created"
		end

		plan = peer.proxy(remote_trsc.plan)
		trsc = Roby::Distributed::Transaction.new(plan, remote_trsc.owners)
		trsc.remote_siblings[peer.remote_id] = remote_trsc.remote_object

		subscriptions << remote_trsc.remote_object
		trsc
	    end

	    def transaction_prepare_commit(trsc)
		Roby::Control.once { peer.connection_space.transaction_prepare_commit(peer.proxy(trsc)) }
		peer.proxy(trsc).freezed!
		nil
	    end
	    def transaction_commit(trsc)
		Roby::Control.once { peer.connection_space.transaction_commit(peer.proxy(trsc)) }
		nil
	    end
	    def transaction_abandon_commit(trsc)
		Roby::Control.once { peer.connection_space.transaction_abandon_commit(peer.proxy(trsc)) }
		nil
	    end
	    def transaction_discard(trsc)
		Roby::Control.once { peer.connection_space.transaction_discard(peer.proxy(trsc)) }
		nil
	    end
	end

	class Peer
	    # Create a sibling for +trsc+ on this peer. If a block is given, yields
	    # the remote transaction object from within the communication thread
	    def transaction_create(trsc)
		unless trsc.kind_of?(Roby::Distributed::Transaction)
		    raise TypeError, "cannot create a non-distributed transaction"
		end

		transmit(:transaction_create, trsc) do |marshalled_transaction|
		    remote_transaction = marshalled_transaction.remote_object
		    trsc.remote_siblings[remote_id] = remote_transaction

		    yield(marshalled_transaction) if block_given?
		end
	    end
	    def transaction_propose(trsc)
		# What do we need to do on the remote side ?
		#   - create a new transaction with the right owners
		#   - create all needed transaction proxys. Transaction proxys
		#     can apply on local and remote tasks
		#   - create all needed remote proxys
		#   - setup all relations
		transaction_create(trsc) do |marshalled_transaction|
		    subscriptions << marshalled_transaction.remote_object

		    subscribed, init = local.subscribe(trsc)
		    init.unshift [remote_server, [:subscribed, subscribed]]
		    transmit(:demux, init) { yield if block_given? }
		end
	    end
	end
    end
end
