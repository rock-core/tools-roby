module Roby
    module Distributed
	class << self
            # The block which is called when a new transaction has been proposed to us.
	    attr_accessor :transaction_handler

	    # Sets up the transaction handler. The given block will be called
	    # in a separate thread whenever a remote peer proposes a new
	    # transaction
	    def on_transaction(&block)
		Distributed.transaction_handler = block
	    end
	end

        # Raised when an operation needs the edition token, while the local
        # plan manager does not have it.
	class NotEditor < RuntimeError; end
        # Raised when a commit is attempted while the transaction is not ready,
        # i.e. the token should be passed once more in the edition ring.
	class NotReady < RuntimeError; end

        # An implementation of a transaction distributed over multiple plan
        # managers.  The transaction modification protocol is based on an
        # edition token, which is passed through all the transaction owners by
        # #edit and #release.
        #
        # Most operations on this distributed transaction must be done outside
        # the control thread, as they are blocking.
        #
        # See DistributedObject for a list of operations valid on distributed objects.
	class Transaction < Roby::Transaction
	    attr_reader :owners
	    attr_reader :token_lock, :token_lock_signal
	    include DistributedObject

            # Create a new distributed transaction based on the given plan. The
            # transaction sole owner is the local plan manager, which is also
            # the owner of the edition token.
	    def initialize(plan, options = {})
		@owners  = [Distributed]
		@editor  = true

		@token_lock = Mutex.new
		@token_lock_signal = ConditionVariable.new

		super
	    end

	    def do_wrap(base_object, create) # :nodoc:
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

	    def copy_object_relations(object, proxy) # :nodoc:
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

            # Announces the transaction on +peer+ or, if +peer+ is nil, to all
            # owners who don't know about it yet. This operation is
            # asynchronous, so the block, if given, will be called for each
            # remote peer which has processed the message.
            #
            # See Peer#transaction_propose
	    def propose(peer = nil, &block)
		if !self_owned?
		    raise OwnershipError, "cannot propose a transaction we don't own"
		end

		if peer
		    peer.transaction_propose(self, &block)
		else
		    (owners - remote_siblings.keys).each do |peer|
			if peer != Roby::Distributed
			    Distributed.debug "proposing #{self} to #{peer}"
			    propose(peer) do
				yield(peer)
			    end
			end
		    end
		end
	    end

	    def add(objects) # :nodoc:
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
	    #   commit_transaction => self
	    #
            # Commits the transaction. This method can only be called by the
            # first editor of the transaction, once all owners have requested
            # no additional modifications.
            #
            # Distributed commits are done in two steps, to make sure that all
            # owners agree to actually perform it. First, the
            # PeerServer#transaction_prepare_commit message is sent, which can
            # return either nil or an error object.
            #
            # If all peers return nil, the actual commit is performed by
            # sending the PeerServer#transaction_commit message. Otherwise, the
            # commit is abandonned by sending the
            # PeerServer#transaction_abandon_commit message to the transaction
            # owners.
	    def commit_transaction(synchro = true)
		if !self_owned?
		    raise OwnershipError, "cannot commit a transaction which is not owned locally. #{self} is owned by #{owners.to_a}"
		elsif synchro
		    if !editor?
			raise NotEditor, "not editor of this transaction"
		    elsif !first_editor?
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
			    super() { yield if block_given? }
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
            # Discards the transaction. Unlike #commit_transaction, this can be
            # called by any of the owners.
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

            # True if we currently have the edition token
            attr_predicate :editor?
            # True if one of the editors request that the token is passed to
            # them once more. The transaction can be committed only when all
            # peers did not request that.
            #
            # See #release
	    attr_reader :edition_reloop

            # True if this plan manager is the first editor, i.e. the plan
            # manager whose responsibility is to manage the edition protocol.
	    def first_editor?
		owners.first == Distributed
	    end
            # Returns the peer which is after this plan manager in the edition
            # order.  The edition token will be sent to this peer by #release
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

            # Waits for the edition token. If a block is given, it is called
            # when the token is achieved, and releases the token when the
            # blocks returns.
	    def edit(reloop = false)
		if Thread.current[:control_mutex_locked]
		    raise "cannot call #edit with the control mutex taken !"
		end

		token_lock.synchronize do
		    while !editor? # not the current editor
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

            # Releases the edition token, giving it to the next owner. If
            # +give_back+ is true, the local plan manager announces that it
            # expects the token to be given back to it once more. The commit is
            # allowed only when all peers have released the edition token
            # without requesting it once more.
            #
            # It sends the #transaction_give_token to the peer returned by
            # #next_editor.
            #
            # Raised NotEditor if the local plan manager is not the current
            # transaction editor.
	    def release(give_back = false)
		token_lock.synchronize do
		    if !editor?
			raise NotEditor, "not editor"
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

            # Intermediate representation of a Roby::Distributed::Transaction
            # object, suitable for representing that transaction in the dRoby
            # protocol.
	    class DRoby < Roby::BasicObject::DRoby
		attr_reader :plan, :options
		def initialize(remote_siblings, owners, plan, options)
		    super(remote_siblings, owners)
		    @plan, @options = plan, options
		end

                # Returns the local representation of this transaction, or
                # raises InvalidRemoteOperation if none exists.
		def proxy(peer)
		    raise InvalidRemoteOperation, "the transaction #{self} does not exist on #{peer.connection_space.name}"
		end

                # Create a local representation for this transaction.
		def sibling(peer)
		    plan = peer.local_object(self.plan)
		    trsc = Roby::Distributed::Transaction.new(plan, peer.local_object(options))
		    update(peer, trsc)
		    trsc.instance_eval do
			@editor  = false
		    end
		    trsc
		end

                # Called when a new sibling has been created locally for a
                # distributed transaction present on +peer+. +trsc+ is the
                # local representation of this transaction.
                #
                # In practice, it announces the new transaction by calling the
                # block stored in Distributed.transaction_handler (if there is
                # one).
                #
                # See PeerServer#created_sibling
		def created_sibling(peer, trsc)
		    Thread.new do
			Thread.current.priority = 0
			begin
			    Distributed.transaction_handler[trsc] if Distributed.transaction_handler
			rescue 
			    Roby::Distributed.warn "transaction handler for #{trsc} failed"
			    Roby::Distributed.warn $!.full_message
			    trsc.invalidate("failed transaction handler")
			end
		    end
		end

		def to_s # :nodoc:
		    "#<dRoby:Trsc#{remote_siblings_to_s} owners=#{owners_to_s} plan=#{plan}>"
		end
	    end

            # Returns a representation of +self+ which can be used to reference
            # it in our communication with +dest+.
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

	module Roby::Task::Proxying
	    def droby_dump(dest) # :nodoc:
		DRoby.new(remote_siblings.droby_dump(dest), owners.droby_dump(dest),
			 Distributed.format(@__getobj__, dest), Distributed.format(plan, dest))
	    end

            # A representation of a distributed transaction proxy suitable for
            # communication with the remote plan managers.
	    class DRoby < Roby::BasicObject::DRoby
                # The DRoby version of the underlying object
		attr_reader :real_object
                # The DRoby representation of the transaction
                attr_reader :transaction
                # Create a new dRoby representation for a transaction proxy.
                # The proxy currently has the given set of remote siblings and
                # owners, is a view on the given real object and is stored in
                # the given transaction. All objects must already be formatted
                # for marshalling using Distributed.format.
		def initialize(remote_siblings, owners, real_object, transaction)
		    super(remote_siblings, owners)
		    @real_object, @transaction = real_object, transaction 
		end

                # Returns the local object matching this dRoby-formatted
                # representation of a remote transaction proxy present on
                # +peer+.
		def proxy(peer)
		    local_real = peer.local_object(real_object)
		    local_object = nil
		    local_transaction = peer.local_object(transaction)
		    Distributed.update(local_transaction) do
			local_object = local_transaction[local_real]
		    end
		    local_object
		end

		def to_s # :nodoc:
                    "#<dRoby:mTrscProxy#{remote_siblings} transaction=#{transaction} real_object=#{real_object}>"
                end
	    end
	end

	module Roby::TaskEventGenerator::Proxying
            # A task event generator has no remote sibling. It is always
            # referenced through its own task.
	    def has_sibling?(peer); false end
            # Create an intermediate object which represent this task event
            # generator in our communication with +dest+
	    def droby_dump(dest)
		Roby::TaskEventGenerator::DRoby.new(controlable?, happened?, Distributed.format(task, dest), symbol)
	    end
	end
    end
end
