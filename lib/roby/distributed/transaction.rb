require 'roby'
require 'roby/distributed/objects'
require 'roby/distributed/proxy'

module Roby
    module Distributed
	class << self
	    attr_accessor :transaction_handler
	    def on_transaction(&block)
		Distributed.transaction_handler = block
	    end
	end

	class NotEditor < RuntimeError; end
	class NotReady < RuntimeError; end
	class Transaction < Roby::Transaction
	    attr_reader :owners
	    attr_reader :editors
	    attr_reader :token_lock, :token_lock_signal
	    include DistributedObject

	    def initialize(plan, options = {})
		super
		@owners  = [Distributed.remote_id].to_set
		@editors = [Distributed.remote_id]
		@editor  = true

		@token_lock = Mutex.new
		@token_lock_signal = ConditionVariable.new
	    end

	    # Add the Peer +peer+ to the list of owners
	    def add_owner(peer, distributed = true)
		peer_id = if peer.respond_to?(:remote_id) then peer.remote_id
			  else peer
			  end

		if !self_owned? && distributed
		    raise NotOwner, "not transaction owner"
		end
		return if @owners.include?(peer_id)

		if distributed
		    remote_siblings.each_value do |remote|
			remote.add_owner(peer_id, false)
		    end
		end
		
		editors << peer_id
		owners  << peer_id
		Distributed.debug { "added owner to #{self}: #{owners.to_a}" }
	    end

	    # Checks that +peer_id+ can be removed from the list of owners
	    def prepare_remove_owner(peer_id)
		each_task(true) do |t|
		    next unless discovered_relations_of?(t, nil, false) 
		    t = t.__getobj__ if t.kind_of?(Roby::Transactions::Proxy)
		    if t.owners.include?(peer_id)
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
		    remote_siblings.each_value do |remote|
			remote.prepare_remove_owner(peer_id)
		    end
		end

		@owners.delete(peer_id)
		remote_siblings.each_value do |remote|
		    remote.remove_owner(peer_id, false)
		end
	    end

	    # Sends the transaction to +peer+. This must be done only once.
	    def propose(peer, &block)
		if !self_owned?
		    raise NotOwner, "cannot propose a transaction we don't own"
		end
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
		if !self_owned?
		    raise NotOwner, "cannot commit a transaction which is not owned locally. #{self} is owned by #{owners.to_a}"
		elsif synchro
		    if !editor? || !first_editor?
			raise NotEditor, "transactions are committed by their first editor"
		    elsif edition_reloop
			raise NotReady, "transaction still needs editing"
		    end
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
	    def abandoned_commit(error)
		Distributed.debug { "abandoned commit of #{self} because of #{error}" }
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

	    attr_reader :editor
	    alias :editor? :editor
	    attr_reader :edition_reloop

	    def first_editor?
		editors.first == Distributed.remote_id
	    end
	    def next_editor
		if editors.last == Distributed.remote_id
		    return editors.first
		end

		editors.each_cons(2) do |first, second|
		    if first == Distributed.remote_id 
			return second
		    end
		end
	    end

	    def edit!(reloop)
		token_lock.synchronize do
		    @editor = true
		    @edition_reloop = reloop
		    token_lock_signal.broadcast
		end
	    end

	    # Waits for the edition token
	    def edit
		token_lock.synchronize do
		    if editor # current editor
			return
		    else
			token_lock_signal.wait(token_lock)
		    end
		end
	    end

	    # Releases the edition token
	    def release(give_back = false)
		token_lock.synchronize do
		    if !editor
			raise ArgumentError, "not editor"
		    else
			reloop = if first_editor?
				     give_back
				 else
				     edition_reloop || give_back
				 end

			return if editors.size == 1
			@editor = false
			Distributed.peer(next_editor).transaction_give_token(self, reloop)
			true
		    end
		end
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
		    Distributed.dump([DRbObject.new(remote_object), plan, owners, editors, options]) 
		end
		def self._load(str)
		    new(*Marshal.load(str))
		end
		def proxy(peer)
		    unless trsc = peer.find_transaction(remote_object, peer.local_object(plan)) 
			raise InvalidRemoteOperation, "the transaction #{remote_object} does not exist on #{peer.connection_space.name}"
		    end
		    trsc
		end

		def to_s
		    #"mdTransaction(#{remote_object.__drbref}/#{plan.remote_object.__drbref})" 
		end

		attr_reader :plan, :owners, :editors, :options
		def initialize(remote_object, plan, owners, editors, options)
		    super(remote_object)
		    @plan, @owners, @editors, @options = plan, owners, editors, options
		end
	    end
	    def droby_dump # :nodoc:
		DRoby.new(self, self.plan, self.owners, self.editors, self.options)
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
		return unless local_real = peer.local_object(real_object)
		return unless local_real.plan

		local_object = nil
		local_transaction = peer.local_object(transaction)
		Distributed.update([local_transaction]) do
		    local_object = local_transaction[local_real]
		end

		if !local_real.self_owned?
		    local_object.extend RemoteTransactionProxy
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

	# This module gets included in the local representation of remote
	# transaction proxies
	module RemoteTransactionProxy
	    include DistributedObject
	    def local?; __getobj__.local? end
	    def owners; plan.owners | __getobj__.owners end
	    def has_sibling?(peer); plan.has_sibling?(peer) end

	    def discover(relation, mark)
		return unless proxying?
		unless !mark || Distributed.updating?([self]) || __getobj__.owners.subset?(plan.owners)
		    raise NotOwner, "transaction owners #{plan.owners.inspect} do not own #{self.to_s}: #{owners.inspect}"
		end

		if mark
		    owners.each do |owner|
			peer = Distributed.peer(owner)
			raise "unknown owner #{owner}" unless peer
			# peer may be nil if the transaction is owned locally
			if !peer.subscribed?(__getobj__.root_object.remote_object(owner))
			    raise "must subscribe to #{__getobj__} on #{peer} before changing its transactions proxies"
			end
		    end
		end

		super
	    end
	end

	class TaskTransactionProxy < Roby::Transactions::Task
	    include RemoteTransactionProxy
	    proxy_for Roby::Distributed::TaskProxy
	end
	class EventGeneratorTransactionProxy < Roby::Transactions::EventGenerator
	    include RemoteTransactionProxy
	    proxy_for Roby::Distributed::EventGeneratorProxy
	end

	class PeerServer
	    def transaction_create(remote_trsc)
		if dtrsc = (peer.local_object(remote_trsc) rescue nil)
		    raise ArgumentError, "#{remote_trsc} is already created"
		end

		plan = peer.local_object(remote_trsc.plan)
		trsc = Roby::Distributed::Transaction.new(plan, remote_trsc.options)
		trsc.instance_eval do
		    @owners  = remote_trsc.owners.to_set
		    @editors = remote_trsc.editors
		    @editor  = false
		end
		trsc.remote_siblings[peer.remote_id] = remote_trsc.remote_object

		subscriptions << remote_trsc.remote_object
		
		Thread.new do
		    begin
			Distributed.transaction_handler[trsc] if Distributed.transaction_handler
		    rescue 
			STDERR.puts "Transaction handler for #{trsc} failed with #{$!.full_message}"
		    end
		end
		trsc
	    end

	    def transaction_prepare_commit(trsc)
		trsc = peer.local_object(trsc)
		Roby::Control.once { peer.connection_space.transaction_prepare_commit(trsc) }
		trsc.freezed!
		nil
	    end
	    def transaction_commit(trsc)
		trsc = peer.local_object(trsc)
		Roby::Control.once { peer.connection_space.transaction_commit(trsc) }
		nil
	    end
	    def transaction_abandon_commit(trsc, error)
		trsc = peer.local_object(trsc)
		Roby::Control.once { peer.connection_space.transaction_abandon_commit(trsc, error) }
		nil
	    end
	    def transaction_discard(trsc)
		trsc = peer.local_object(trsc)
		Roby::Control.once { peer.connection_space.transaction_discard(trsc) }
		nil
	    end
	    def transaction_give_token(trsc, needs_edition)
		trsc = peer.local_object(trsc)
		trsc.edit!(needs_edition)
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

		    local.subscribe(trsc)
		    synchro_point do
			yield if block_given?
		    end
		end
	    end

	    def transaction_give_token(trsc, needs_edition)
		transmit(:transaction_give_token, trsc, needs_edition)
	    end
	end
    end
end
