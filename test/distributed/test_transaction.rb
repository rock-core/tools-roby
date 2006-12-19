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
	apply_remote_command
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

    def test_transaction_create
	peer2peer do |remote|
	    class << remote
		include Test::Unit::Assertions
		def test_find_transaction(marshalled_trsc)
		    _, peer = peers.to_a[0]
		    assert(trsc = peer.find_transaction(marshalled_trsc.remote_object))
		    assert_equal(marshalled_trsc.remote_object, trsc.remote_siblings[peer.remote_id])
		    assert(trsc.owners.include?(peer.remote_id))
		    assert(trsc.owners.include?(Roby::Distributed.remote_id))
		end
	    end
	end
	trsc = Distributed::Transaction.new(plan)
	remote_trsc = nil
	trsc.self_owned
	remote_peer.transaction_create(trsc) { |remote_trsc| remote_trsc = remote_trsc.remote_object }
	apply_remote_command
	trsc.add_owner remote_peer

	assert_equal(remote_trsc, trsc.remote_siblings[remote_peer.remote_id])
	assert(remote_trsc.remote_siblings.has_key?(local_peer.remote_id), remote_trsc.remote_siblings.keys)
	remote.test_find_transaction(trsc)
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
	remote_peer.transaction_create(trsc) { |remote_trsc| remote_trsc = remote_trsc.remote_object }
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

	# Check we still can remove the peer from the transaction owners
	trsc.add_owner(remote_peer)
	trsc.remove_owner(remote_peer)

	# Try to discover the task
	task = Task.new
	assert_raises(NotOwner) { t_task.discover(TaskStructure::Hierarchy, true) }
	assert_raises(NotOwner) { t_task.realized_by task }
	assert(! task.plan)
	trsc.add_owner remote_peer
	assert_nothing_raised { t_task.discover(TaskStructure::Hierarchy, true) }
	assert_raises(NotOwner) { t_task.realized_by task }
	assert_raises(NotOwner) { t_task.event(:start).on task.event(:start) }
	assert_raises(NotOwner) { task.realized_by t_task }
	assert_raises(NotOwner) { task.event(:start).on t_task.event(:start) }
	assert_raises(NotOwner) { trsc.discard_transaction }
	assert_raises(NotOwner) { trsc.commit_transaction }

	trsc.self_owned = true
	assert_nothing_raised { t_task.realized_by task }
	assert_nothing_raised { t_task.event(:start).on task.event(:start) }
	assert_nothing_raised { task.realized_by t_task }
	assert_nothing_raised { task.event(:start).on t_task.event(:start) }
	assert_raises(OwnershipError) { trsc.remove_owner remote_peer }
	assert_raises(OwnershipError) { trsc.self_owned = false }
	trsc.self_owned
	assert_nothing_raised { trsc.discard_transaction }
	apply_remote_command
	Control.instance.process_events
    end

    def build_transaction(trsc)
	r_task = remote_peer.proxy(remote_task(:id => 1))
	t_task = trsc[r_task]
	trsc.discover(t_task)

	# Now, add a task of our own and link the remote and the local
	task = SimpleTask.new :id => 2
	trsc.discover(task)
	trsc.self_owned

	# Add relations
	assert(t_task.owners.subset?(trsc.owners))
	assert(!t_task.read_only?)
	assert(!task.read_only?)
	assert(!t_task.event(:start).read_only?)
	assert(!t_task.event(:stop).read_only?)
	assert(!task.event(:start).read_only?)
	assert(!task.event(:stop).read_only?)
	t_task.realized_by task
	task.realized_by t_task
	t_task.event(:start).on task.event(:start)
	task.event(:stop).on t_task.event(:stop)

	[task, r_task]
    end

    # Checks that +plan+ looks like the result of #build_transaction
    def check_resulting_plan(plan)
	Control.instance.process_events

	assert_equal(3, plan.known_tasks.size)
	r_task = plan.known_tasks.find { |t| t.arguments[:id] == 1 }
	task   = plan.known_tasks.find { |t| t.arguments[:id] == 2 }

	assert_equal(1, r_task.child_objects(Roby::TaskStructure::Hierarchy).size)
	assert(r_task.child_object?(task, Roby::TaskStructure::Hierarchy))
	assert_equal(1, r_task.event(:start).child_objects(Roby::EventStructure::Signal).size)
	assert(r_task.event(:start).child_object?(task.event(:start), Roby::EventStructure::Signal))
	assert_equal(1, task.child_objects(Roby::TaskStructure::Hierarchy).size)
	assert(task.child_object?(r_task, Roby::TaskStructure::Hierarchy))
	assert_equal(1, task.event(:stop).child_objects(Roby::EventStructure::Signal).size)
	assert(task.event(:stop).child_object?(r_task.event(:stop), Roby::EventStructure::Signal))
    end

    # Commit the transaction and checks the result
    def check_transaction_commit(trsc, task, r_task)
	# Commit the transaction
	did_commit = false
	trsc.commit_transaction do |commited_transaction, did_commit| 
	    assert_equal(trsc, commited_transaction) 
	    assert(did_commit)
	end

	# Send prepare_commit_transaction to the remote host and read its reply
	apply_remote_command

	assert(r_task.child_object?(task, TaskStructure::Hierarchy))
	remote.check_plan
	check_resulting_plan(local.plan)
    end

    def test_argument_updates
	peer2peer do |remote|
	    remote.plan.insert(Task.new(:id => 2))
	    def remote.set_argument(task)
		peer = Distributed.peers.find { true }.last
		task = peer.proxy(task)
		task.arguments[:foo] = :bar
		nil
	    end
	end
	r_task = remote_peer.proxy(remote_task(:id => 2))

	assert_raises(NotOwner) { r_task.arguments[:foo] = :bar }
	apply_remote_command

	trsc   = Roby::Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.self_owned
	trsc.propose(remote_peer)

	t_task = trsc[r_task]
	assert_raises(NotOwner) { t_task.arguments[:foo] = :bar }
	apply_remote_command

	task = Task.new(:id => 2)
	t_task = trsc[task]
	assert_nothing_raised { remote.set_argument(t_task) }
	apply_remote_command

	assert_equal(:bar, task.arguments[:foo], task)
    end

    def test_propose_commit
	peer2peer do |remote|
	    testcase = self
	    remote.plan.insert(SimpleTask.new(:id => 1))

	    remote.class.class_eval do
		define_method(:check_transaction) do |trsc|
		    testcase.check_resulting_plan(trsc)
		end
		define_method(:check_plan) { testcase.check_resulting_plan(remote.plan) }
	    end
	end
	trsc   = Roby::Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.self_owned

	task, r_task = build_transaction(trsc)

	# Send the transaction to remote_peer and commit it
	trsc.propose(remote_peer)
	apply_remote_command
	r_trsc = trsc.remote_siblings[remote_peer.remote_id]
	assert(r_trsc)
	remote.check_transaction(r_trsc)

	check_transaction_commit(trsc, task, r_task)
    end

    def test_synchronization
	peer2peer do |remote|
	    testcase = self
	    remote.plan.insert(SimpleTask.new(:id => 1))

	    remote.class.class_eval do
		define_method(:check_transaction) do |trsc|
		    testcase.check_resulting_plan(trsc)
		end
		define_method(:check_plan) { testcase.check_resulting_plan(remote.plan) }
	    end
	end

	# Create a transaction for the plan and send it right away
	trsc = Roby::Distributed::Transaction.new(plan)
	trsc.self_owned
	trsc.add_owner remote_peer
	trsc.propose(remote_peer)
	apply_remote_command

	assert(r_trsc = trsc.remote_siblings[remote_peer.remote_id])
	assert(remote_peer.subscribed?(r_trsc), remote_peer.subscriptions.to_a.to_s)

	task, r_task = build_transaction(trsc)

	# Check that the remote transaction has been updated
	apply_remote_command
	remote.check_transaction(r_trsc)
	check_resulting_plan(trsc)

	# Commit the transaction
	check_transaction_commit(trsc, task, r_task)
    end
end

