$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'distributed/common.rb'
require 'roby/distributed/transaction.rb'
require 'mockups/tasks'

class TC_DistributedTransaction < Test::Unit::TestCase
    include DistributedTestCommon

    include Roby
    include Roby::Distributed

    def setup
	Roby::Distributed.allow_remote_access Roby::Distributed::Peer
	super
    end

    def teardown 
	Distributed.unpublish
	Distributed.state = nil

	super
    end

    def test_marshal_transactions
	peer2peer do |remote|
	    class << remote
		attr_reader :plan
		def transaction
		    @plan ||= Plan.new
		    Roby::Transaction.new(plan)
		end
		def d_transaction
		    @plan ||= Plan.new
		    Roby::Distributed::Transaction.new(plan)
		end
	    end
	end

	trsc = remote.transaction
	assert_kind_of(Plan::DRoby, trsc)
	assert_equal(local.plan, remote_peer.proxy(trsc))

	dtrsc = remote.d_transaction
	assert_kind_of(Distributed::Transaction::DRoby, dtrsc)
	assert_equal(remote.plan.remote_object, dtrsc.plan.remote_object)
	assert_raises(InvalidRemoteOperation) { remote_peer.proxy(dtrsc) }
    end

    def test_create_transaction
	peer2peer do |remote|
	    def remote.test_find_transaction(trsc)
		peers.to_a[0][1].find_transaction(trsc.remote_object)
	    end
	end
	trsc = Distributed::Transaction.new(plan)
	remote_trsc = nil
	remote_peer.create_transaction(trsc) { |remote_trsc| }
	apply_remote_command
	assert_equal(remote_trsc, trsc.remote_siblings[remote_peer.remote_id])
	assert(remote_trsc.remote_siblings.has_key?(local_peer.remote_id), remote_trsc.remote_siblings.keys)
	assert(remote.test_find_transaction(trsc), trsc.object_id)
    end

    def test_marshal_transaction_proxies
	peer2peer do |remote|
	    class << remote
		def get_marshalled_tproxy(trsc, task)
		    peer = peers.to_a[0][1]
		    task = peer.proxy(task)
		    trsc[task]
		end
	    end
	end
	trsc = Distributed::Transaction.new(plan)
	remote_trsc = nil
	remote_peer.create_transaction(trsc) { |remote_trsc| }
	apply_remote_command

	# Check that marshalling the remote view of a local transaction proxy
	# returns the local proxy itself
	t = Task.new
	plan.discover(t)
	p = trsc[t]
	assert_equal(p, remote_peer.proxy(remote.get_marshalled_tproxy(remote_trsc, t)))
    end

    def test_ownership
	peer2peer do |remote|
	    remote.plan.insert(Task.new(:id => 1))
	end
	r_task = remote_peer.proxy(remote_task(:id => 1))
	assert(!Distributed.owns?(r_task))
	assert(remote_peer.owns?(r_task))

	# Create a transaction for the plan
	trsc = Roby::Distributed::Transaction.new(plan)
	assert(!Distributed.owns?(trsc))
	assert(!remote_peer.owns?(trsc))

	trsc.add_owner remote_peer
	assert(remote_peer.owns?(trsc))
	trsc.remove_owner remote_peer
	assert(!remote_peer.owns?(trsc))

	t_task = trsc[r_task]
	assert(!Distributed.owns?(r_task))
	assert(remote_peer.owns?(t_task))
	trsc.insert(t_task)

	# Check we still can remove the peer from the transaction owners
	trsc.add_owner(remote_peer)
	trsc.remove_owner(remote_peer)

	# Try to discover the task
	task = Task.new
	assert_raises(NotOwner) { t_task.discover(TaskStructure::Hierarchy) }
	assert_raises(NotOwner) { t_task.realized_by task }
	trsc.add_owner remote_peer
	assert_nothing_raised { t_task.discover(TaskStructure::Hierarchy) }
	assert_raises(NotOwner) { t_task.realized_by task }
	assert_raises(NotOwner) { trsc.discard_transaction }

	trsc.self_owned = true
	assert_nothing_raised { t_task.realized_by task }
	assert_raises(OwnershipError) { trsc.remove_owner remote_peer }
	assert_raises(OwnershipError) { trsc.self_owned = false }
	trsc.self_owned
	assert_nothing_raised { trsc.discard_transaction }
	apply_remote_command
	Control.instance.process_events
    end

    def test_propose_commit
	peer2peer do |remote|
	    remote.plan.insert(Task.new(:id => 1))
	    class << remote
		include Test::Unit::Assertions
	    end
	    def remote.check_transaction(trsc)
		r_task, task = nil
		assert_kind_of(Roby::Distributed::Transaction, trsc)
		assert_equal(2, trsc.known_tasks.size)
		trsc.known_tasks.each do |t|
		    if t.arguments[:id] == 1
			assert_kind_of(Transactions::Proxy, t)
			r_task = t
		    else
			assert_kind_of(Roby::Distributed::RemoteObjectProxy, t)
			task = t
		    end
		end

		assert_equal(1, r_task.child_objects(Roby::TaskStructure::Hierarchy).size)
		assert(r_task.child_object?(task, Roby::TaskStructure::Hierarchy))
	    end
	    def remote.check_plan
		Control.instance.process_events
		r_task, task = nil
		assert_equal(2, plan.known_tasks.size)
		plan.known_tasks.each do |t|
		    if t.arguments[:id] == 1 then r_task = t
		    else task = t
		    end
		end

		assert(r_task && task)
		assert_equal(1, r_task.child_objects(Roby::TaskStructure::Hierarchy).size)
		assert(r_task.child_object?(task, Roby::TaskStructure::Hierarchy))
	    end
	end
	trsc   = Roby::Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	r_task = remote_peer.proxy(remote_task(:id => 1))
	t_task = trsc[r_task]
	trsc.discover(t_task)

	# Now, add a task of our own and link the remote and the local
	task = Task.new :id => 2
	trsc.discover(task)
	trsc.self_owned
	t_task.realized_by task

	# Send the transaction to remote_peer and commit it
	trsc.propose(remote_peer)
	apply_remote_command
	r_trsc = trsc.remote_siblings[remote_peer.remote_id]
	assert(r_trsc)
	remote.check_transaction(r_trsc)

	# Commit the transaction
	did_commit = false
	trsc.commit_transaction do |commited_transaction, did_commit| 
	    assert_equal(trsc, commited_transaction) 
	    assert(did_commit)
	end

	# Send prepare_commit_transaction to the remote host and read its reply
	apply_remote_command
	# Call commit_transaction
	Control.instance.process_events
	# Send commit_transaction to the remote host and read its reply
	apply_remote_command
	# read the commit result given to 
	Control.instance.process_events

	assert(r_task.child_object?(task, TaskStructure::Hierarchy))
	remote.check_plan

	remote_children = r_task.remote_object(remote_peer.remote_id).child_objects(Roby::TaskStructure::Hierarchy)
	assert_equal(task, remote_children.find { true }.remote_object)
    end

    def test_synchronization
	peer2peer do |remote|
	    remote.plan.insert(Task.new(:id => 1))
	    class << remote
		include Test::Unit::Assertions
	    end
	    def remote.check_transaction(trsc)
		r_task, task = nil
		trsc.known_tasks.each do |t|
		    if t.arguments[:id] == 1
			assert_kind_of(Transactions::Proxy, t)
			r_task = t
		    else
			assert_kind_of(Distributed::RemoteTaskProxy, t)
			task = t
		    end
		end

		assert(r_task.child_object?(task, Roby::TaskStructure::Hierarchy))
	    end
	end

	# Create a transaction for the plan and send it right away
	trsc = Roby::Distributed::Transaction.new(plan)
	trsc.self_owned
	trsc.add_owner remote_peer
	trsc.propose(remote_peer)
	apply_remote_command

	r_task = remote_peer.proxy(remote_task(:id => 1))
	t_task = trsc[r_task]
	task = Task.new :id => 2
	trsc.insert(task)
	t_task.realized_by task
	apply_remote_command

	# Check that the remote transaction has been updated
	r_trsc = trsc.remote_siblings[remote_peer.remote_id]
	remote.check_transaction(r_trsc)

	# Commit the transaction
	trsc.commit
	assert(r_task.child_object?(task, TaskStructure::Hierarchy))
	assert_equal(task, r_task.remote_object.child_objects(Roby::TaskStructure::Hierarchy).first)
    end
end

