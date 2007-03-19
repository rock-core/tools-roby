require 'roby'
require 'roby/distributed/distributed_object'
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
	    attr_reader :token_lock, :token_lock_signal
	    include DistributedObject

	    def initialize(plan, options = {})
		super
		@owners  = [Distributed]
		@editor  = true

		@token_lock = Mutex.new
		@token_lock_signal = ConditionVariable.new
	    end

	    def do_wrap(base_object, create)
		# It is allowed to add objects in a transaction only if
		#   * the object is not distribuable. It means that we are
		#     annotating *locally* remote tasks (like it is done for
		#     ConnectionTask for instance).
		#   * the object is owned by the transaction owners
		if create && (base_object.distribute? && !(base_object.owners - owners).empty?)
		    raise NotOwner, "plan owners #{owners} do not own #{base_object}: #{base_object.owners}"
		end

		temporarily_subscribed = !base_object.updated?
		if temporarily_subscribed
		    peer = base_object.owners.first
		    base_object = peer.subscribe(base_object)
		end

		if object = super
		    object.extend DistributedObject
		    if !Distributed.updating?(self) && object.root_object?
			updated_peers.each do |peer|
			    next if base_object.update_on?(peer) || !base_object.distribute?
			    peer.local.subscribe(base_object)
			    peer.synchro_point
			end
		    end
		end

		object

	    ensure
		if temporarily_subscribed
		    peer.unsubscribe(base_object)
		end
	    end

	    # Checks that +peer+ can be removed from the list of owners
	    def prepare_remove_owner(peer)
		known_tasks.each do |t|
		    t = t.__getobj__ if t.respond_to?(:__getobj__)
		    if peer.owns?(t) && t.distribute?
			raise OwnershipError, "#{peer} still owns tasks in the transaction (#{t})"
		    end
		end
		nil
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
			unless Distributed.updating?(object) || 
			    Distributed.owns?(object) || 
			    (object.owners - owners).empty?

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
		    result = call_owners(:transaction_prepare_commit, self)
		    error = result.find_all { |_, returned| returned }
		    if !error.empty?
			call_owners(:transaction_abandon_commit, self, error)
			return false
		    else
			call_owners(:transaction_commit, self)
			return true
		    end
		else
		    all_objects = (known_tasks | discovered_objects)
		    proxy_objects.each_key { |o| all_objects << o }
		    Distributed.update_all(all_objects) do
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
		    call_siblings(:transaction_discard, self)
		else super()
		end
		self
	    end

	    attr_reader :editor
	    alias :editor? :editor
	    attr_reader :edition_reloop

	    def first_editor?
		owners.first == Distributed
	    end
	    def next_editor
		if owners.last == Distributed
		    return owners.first
		end

		owners.each_cons(2) do |first, second|
		    if first == Distributed
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

			return if owners.size == 1
			@editor = false
			next_editor.transaction_give_token(self, reloop)
			true
		    end
		end
	    end

	    # Distributed transactions are marshalled as DRbObjects and #proxy
	    # returns their sibling in the remote pDB (or raises if there is none)
	    class DRoby < Roby::Plan::DRoby # :nodoc:
		def _dump(lvl)
		    Marshal.dump([remote_object, plan, owners, options]) 
		end
		def self._load(str)
		    new(*Marshal.load(str))
		end
		def proxy(peer)
		    raise InvalidRemoteOperation, "the transaction #{remote_object} does not exist on #{peer.connection_space.name}"
		end

		def sibling(peer)
		    plan = peer.local_object(self.plan)
		    trsc = Roby::Distributed::Transaction.new(plan, options)
		    owners = self.owners
		    trsc.instance_eval do
			@owners  = owners
			@editor  = false
		    end
		    trsc
		end

		def created_sibling(peer, trsc)
		    Thread.new do
			Thread.current.priority = 0
			begin
			    Distributed.transaction_handler[trsc] if Distributed.transaction_handler
			rescue 
			    STDERR.puts "Transaction handler for #{trsc} failed with #{$!.full_message}"
			end
		    end
		end

		def to_s
		    #"mdTransaction(#{remote_object.__drbref}/#{plan.remote_object.__drbref})" 
		end

		attr_reader :plan, :owners, :options
		def initialize(remote_object, plan, owners, options)
		    super(remote_object)
		    @plan, @owners, @options = plan, owners, options
		end
	    end
	    def droby_dump(dest) # :nodoc:
		DRoby.new(drb_object, self.plan.droby_dump(dest), self.owners.droby_dump(dest), self.options)
	    end
	end

	class MarshalledRemoteTransactionProxy # :nodoc:
	    def self._load(str)
		MarshalledRemoteTransactionProxy.new(*Marshal.load(str))
	    end
	    def _dump(lvl)
		Marshal.dump([remote_object, real_object, transaction])
	    end
	    def proxy(peer)
		return unless local_real = peer.local_object(real_object)

		local_object = nil
		local_transaction = peer.local_object(transaction)
		Distributed.update(local_transaction) do
		    local_object = local_transaction[local_real]
		end

		if !local_real.self_owned?
		    local_object.extend RemoteTransactionProxy
		    local_object.transaction = local_transaction
		end

		local_object.sibling_of(remote_object, peer) if local_object.root_object?
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
	    def droby_dump(dest) # :nodoc:
		MarshalledRemoteTransactionProxy.new(drb_object, @__getobj__.droby_dump(dest), transaction.droby_dump(dest))
	    end
	end

	# This module gets included in the local representation of remote
	# transaction proxies
	module RemoteTransactionProxy
	    include DistributedObject
	    attr_accessor :transaction

	    def owners; __getobj__.owners end

	    def discover(relation, mark)
		return unless proxying?
		unless !mark || Distributed.updating?(self) || (__getobj__.owners - plan.owners).empty?
		    raise NotOwner, "transaction owners #{plan.owners} do not own #{self}: #{owners}"
		end

		if mark
		    owners.each do |owner|
			if !Distributed.updating?(self) && !__getobj__.root_object.updated?
			    raise "must subscribe to #{__getobj__} on #{owner} before changing its transactions proxies"
			end
		    end
		end

		super
	    end
	end

	class EventGeneratorTransactionProxy < Roby::Transactions::EventGenerator
	    include RemoteTransactionProxy
	    proxy_for Roby::Distributed::EventGeneratorProxy
	end
	class TaskTransactionProxy < Roby::Transactions::Task
	    include RemoteTransactionProxy
	    proxy_for Roby::Distributed::TaskProxy
	end
	class TaskEventGeneratorTransactionProxy < Roby::Transactions::TaskEventGenerator
	    include RemoteTransactionProxy
	    proxy_for Roby::Distributed::TaskEventGeneratorProxy
	end

	class PeerServer
	    def transaction_prepare_commit(trsc)
		trsc = peer.local_object(trsc)
		execute { peer.connection_space.transaction_prepare_commit(trsc) }
		trsc.freezed!
		nil
	    end
	    def transaction_commit(trsc)
		trsc = peer.local_object(trsc)
		execute { peer.connection_space.transaction_commit(trsc) }
		nil
	    end
	    def transaction_abandon_commit(trsc, error)
		trsc = peer.local_object(trsc)
		execute { peer.connection_space.transaction_abandon_commit(trsc, error) }
		nil
	    end
	    def transaction_discard(trsc)
		trsc = peer.local_object(trsc)
		execute do
		    peer.connection_space.transaction_discard(trsc)
		end
		nil
	    end
	    def transaction_give_token(trsc, needs_edition)
		trsc = peer.local_object(trsc)
		trsc.edit!(needs_edition)
		nil
	    end
	end

	class Peer
	    def transaction_propose(trsc)
		create_sibling(trsc)
		nil
	    end

	    def transaction_give_token(trsc, needs_edition)
		call(:transaction_give_token, trsc, needs_edition)
	    end
	end
    end
end
