require 'roby'
require 'roby/distributed/distributed_object'
require 'roby/distributed/proxy'

module Roby
    module Distributed
	class << self
	    attr_accessor :transaction_handler

	    # Sets up the transaction handler. The given block will be called
	    # in a separate thread whenever a remote peer proposes a new
	    # transaction
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
		@owners  = [Distributed]
		@editor  = true

		@token_lock = Mutex.new
		@token_lock_signal = ConditionVariable.new

		super
	    end

	    def do_wrap(base_object, create)
		# It is allowed to add objects in a transaction only if
		#   * the object is not distribuable. It means that we are
		#     annotating *locally* remote tasks (like it is done for
		#     ConnectionTask for instance).
		#   * the object is owned by the transaction owners
		if create && (base_object.distribute? && !(base_object.owners - owners).empty?)
		    raise OwnershipError, "plan owners #{owners} do not own #{base_object}: #{base_object.owners}"
		end

		temporarily_subscribed = !base_object.updated?
		if temporarily_subscribed
		    peer = base_object.owners.first
		    base_object = peer.subscribe(base_object)
		end

		if object = super
		    object.extend DistributedObject
		    if !Distributed.updating?(self) && object.root_object? && base_object.distribute?
			# The new proxy has been sent to remote hosts since it
			# has been discovered in the transaction. Nonetheless,
			# we don't want to return from #wrap until we know its
			# sibling. Add a synchro point to wait for that
		        updated_peers.each do |peer|
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

	    def copy_object_relations(object, proxy)
		# If the transaction is being updated, it means that we are
		# discovering the new transaction. In that case, no need to
		# discover the plan relations since our peer will send us all
		# transaction relations
		unless Distributed.updating?(self)
		    super
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
		    raise OwnershipError, "cannot propose a transaction we don't own"
		end
		peer.transaction_propose(self, &block)
	    end

	    def discover(objects)
		if objects
		    events, tasks = partition_event_task(objects)
		    for object in (events || []) + (tasks || [])
			unless Distributed.updating?(object) || 
			    Distributed.owns?(object) || 
			    (object.owners - owners).empty?

			    raise OwnershipError, "#{object} is not owned by #{owners.to_a} (#{object.owners.to_a})"
			end
		    end
		    super(events) if events
		    super(tasks) if tasks
		else
		    super
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
		if !self_owned?
		    raise OwnershipError, "cannot commit a transaction which is not owned locally. #{self} is owned by #{owners.to_a}"
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
		    all_objects = known_tasks.dup
		    proxy_objects.each_key { |o| all_objects << o }
		    Distributed.update(self) do
			Distributed.update_all(all_objects) do
			    super()
			end
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
		    raise OwnershipError, "cannot discard a transaction which is not owned locally. #{self} is owned by #{owners}"
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
	    def edit(reloop = false)
		if Thread.current[:control_mutex_locked]
		    raise "cannot call #edit with the control mutex taken !"
		end

		token_lock.synchronize do
		    if !editor # not the current editor
			token_lock_signal.wait(token_lock)
		    end
		end

		if block_given?
		    begin
			yield
		    ensure
			release(reloop)
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

	    class DRoby < Roby::BasicObject::DRoby # :nodoc:
		attr_reader :plan, :options
		def initialize(remote_siblings, owners, plan, options)
		    super(remote_siblings, owners)
		    @plan, @options = plan, options
		end

		def proxy(peer)
		    raise InvalidRemoteOperation, "the transaction #{self} does not exist on #{peer.connection_space.name}"
		end

		def sibling(peer)
		    plan = peer.local_object(self.plan)
		    trsc = Roby::Distributed::Transaction.new(plan, peer.local_object(options))
		    update(peer, trsc)
		    trsc.instance_eval do
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
			    Roby.warn "transaction handler for #{trsc} failed"
			    Roby.warn $!.full_message
			    trsc.invalidate("failed transaction handler")
			end
		    end
		end

		def to_s
		    "#<dRoby:Trsc#{remote_siblings_to_s} owners=#{owners_to_s} plan=#{plan}>"
		end
	    end
	    def droby_dump(dest) # :nodoc:
		if remote_siblings.has_key?(dest)
		    remote_id
		else
		    DRoby.new(remote_siblings.droby_dump(dest), owners.droby_dump(dest), 
			      plan.droby_dump(dest), 
			      options.droby_dump(dest))
		end
	    end
	end

	module Roby::Transaction::Proxy
	    def droby_dump(dest) # :nodoc:
		DRoby.new(remote_siblings.droby_dump(dest), owners.droby_dump(dest),
			 Distributed.format(@__getobj__, dest), Distributed.format(transaction, dest))
	    end
	    class DRoby < Roby::BasicObject::DRoby
		attr_reader :real_object, :transaction
		def initialize(remote_siblings, owners, real_object, transaction)
		    super(remote_siblings, owners)
		    @real_object, @transaction = real_object, transaction 
		end

		def proxy(peer)
		    local_real = peer.local_object(real_object)
		    local_object = nil
		    local_transaction = peer.local_object(transaction)
		    Distributed.update(local_transaction) do
			local_object = local_transaction[local_real]
		    end
		    local_object
		end

		def to_s; "#<dRoby:mTrscProxy#{remote_siblings} transaction=#{transaction} real_object=#{real_object}>" end
	    end
	end

	class Roby::Transactions::TaskEventGenerator
	    def has_sibling?(peer); false end
	    def droby_dump(dest)
		Roby::TaskEventGenerator::DRoby.new(controlable?, happened?, Distributed.format(task, dest), symbol)
	    end
	end

	class PeerServer
	    def transaction_prepare_commit(trsc)
		trsc = peer.local_object(trsc)
		peer.connection_space.transaction_prepare_commit(trsc)
		trsc.freezed!
		nil
	    end
	    def transaction_commit(trsc)
		trsc = peer.local_object(trsc)
		peer.connection_space.transaction_commit(trsc)
		nil
	    end
	    def transaction_abandon_commit(trsc, error)
		trsc = peer.local_object(trsc)
		peer.connection_space.transaction_abandon_commit(trsc, error)
		nil
	    end
	    def transaction_discard(trsc)
		trsc = peer.local_object(trsc)
		peer.connection_space.transaction_discard(trsc)
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
		synchro_point
		create_sibling(trsc)
		nil
	    end

	    def transaction_give_token(trsc, needs_edition)
		call(:transaction_give_token, trsc, needs_edition)
	    end
	end
    end
end
