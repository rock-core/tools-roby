require 'roby/distributed/objects'
require 'roby/distributed/proxy'
require 'roby/transactions'

module Roby
    module Distributed
	class Transaction < Roby::Transaction
	    include DistributedObject

	    attr_reader :owners
	    def initialize(plan, owners = nil)
		@owners = ValueSet.new
		@owners.merge(owners) if owners
		super(plan)
	    end

	    def self_owned?; @owners.include?(Distributed) end
	    def self_owned; self.self_owned = true end
	    def self_owned=(flag)
		if flag then add_owner(Distributed)
		else remove_owner(Distributed)
		end
	    end

	    # Add the Peer +peer+ to the list of owners
	    def add_owner(peer); @owners << peer.remote_id end
	    # Removes +peer+ from the list of owners. Raises OwnershipError if
	    # there are modified tasks in this transaction which are owned by
	    # +peer+
	    def remove_owner(peer, do_check = true)
		if do_check
		    each_task(true) do |t|
			if discovered_relations_of?(t) && peer.owns?(t)
			    raise OwnershipError, "#{peer} still owns tasks in the transaction (#{t})"
			end
		    end
		end

		@owners.delete(peer.remote_id)
	    end

	    # Sends the transaction to +peer+
	    def propose(peer)
		peer.propose_transaction(self)
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

		    Distributed.peer(remote_id).send(*args) do |result|
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
	    # #abandoned_transaction_commit is called as well.
	    def commit_transaction(synchro = true)
		unless Distributed.owns?(self)
		    raise NotOwner, "cannot commit a transaction which is not owned locally. #{self} is owned by #{owners.to_a}"
		end

		if synchro
		    error = nil
		    apply_to_owners(false, :prepare_transaction_commit, self) do |done, result|
			error ||= result
			if done
			    if error
				apply_to_owners(true, :abandon_commit, self, error)
				Control.once { yield(self, false) } if block_given?
			    else
				Control.once do
				    apply_to_owners(false, :commit_transaction, self) do |done, _|
					Control.once { yield(self, true) } if block_given? && done
				    end
				end
			    end
			end
		    end
		else
		    affected_tasks = known_tasks(true).map { |o| may_unwrap(o) }
		    Distributed.update(affected_tasks) { super() }
		end

		self
	    end

	    # Hook called when the transaction commit has been abandoned
	    # because a owner refused it. +reason+ is the value returned by
	    # this peer.
	    def abandoned_transaction_commit(reason)
		Roby.debug { "abandoned commit of #{self} because of #{error}" }
		super if defined? super 
	    end

	    # Discards the transaction. Unlike #commit_transaction, this is
	    # done synchronously on the local plan and cannot be canceled by
	    # remote peers
	    def discard_transaction(synchro = true) # :nodoc:
		unless Distributed.owns?(self)
		    raise NotOwner, "cannot discard a transaction which is not owned locally. #{self} is owned by #{owners}"
		end

		if synchro
		    apply_to_owners(true, :discard_transaction, self)
		else super()
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
	    class DRoby < Roby::Plan::DRoby
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

		attr_reader :plan, :owners
		def initialize(remote_object, plan, owners)
		    super(remote_object)
		    @plan, @owners = plan, owners
		end
	    end
	    def droby_dump
		DRoby.new(self, self.plan, self.owners)
	    end
	end

	class MarshalledRemoteTransactionProxy
	    def self._load(str)
		MarshalledRemoteTransactionProxy.new(*Marshal.load(str))
	    end
	    def _dump(lvl)
		Distributed.dump([DRbObject.new(remote_object), real_object, transaction])
	    end
	    def proxy(peer)
		local_object = peer.proxy(transaction)[peer.proxy(real_object)]
		if local_object.respond_to?(:remote_siblings)
		    local_object.remote_siblings[peer.remote_id] = remote_object
		end
		local_object
	    end

	    attr_reader :remote_object, :real_object, :transaction
	    def initialize(remote_object, real_object, transaction)
		@remote_object, @real_object, @transaction = 
		    remote_object, real_object, transaction 
	    end
	end
	module Roby::Transaction::Proxy
	    def droby_dump
		MarshalledRemoteTransactionProxy.new(self, @__getobj__, transaction)
	    end
	end
	module RemoteTransactionProxy
	    include DistributedObject

	    def discover(relation)
		unless plan.owners.include_all?(owners)
		    raise NotOwner, "transaction owners #{plan.owners.to_a.to_s} do not own #{self.to_s}: #{owners.to_a.to_s}"
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
    end
end
