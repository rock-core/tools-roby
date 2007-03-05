$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'

class TC_DistributedTransaction < Test::Unit::TestCase
    include Roby::Distributed::Test

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
	assert_equal(local.plan, remote_peer.local_object(trsc))

	dtrsc = remote.d_transaction
	assert_kind_of(Distributed::Transaction::DRoby, dtrsc)
	assert_equal(remote.plan.remote_object, dtrsc.plan.remote_object)
	assert_raises(InvalidRemoteOperation) { remote_peer.local_object(dtrsc) }
    end

    def test_transaction_create
	peer2peer(true) do |remote|
	    class << remote
		include Test::Unit::Assertions
		def test_find_transaction(marshalled_trsc)
		    assert(trsc = local_peer.local_object(marshalled_trsc))
		    assert_equal(marshalled_trsc.remote_object, trsc.remote_siblings[local_peer])
		    assert_equal([local_peer, Roby::Distributed], trsc.owners)
		    assert(!trsc.first_editor?)
		    assert(!trsc.editor?)
		    assert(trsc.conflict_solver.kind_of?(Roby::SolverIgnoreUpdate))
		    trsc
		end
	    end
	end
	trsc = Distributed::Transaction.new(plan, :conflict_solver => SolverIgnoreUpdate.new)
	assert(trsc.self_owned?)
	assert(trsc.first_editor?)
	assert(trsc.editor?)

	remote_peer.create_sibling(trsc)
	trsc.add_owner remote_peer
	assert_equal([Distributed, remote_peer], trsc.owners)
	assert(trsc.has_sibling?(remote_peer))
	remote.test_find_transaction(trsc)

	assert(trsc.editor?)
    end

    def test_transaction_proxies
	peer2peer(true) do |remote|
	    class << remote
		include Test::Unit::Assertions
		def marshalled_transaction_proxy(trsc, task)
		    task = local_peer.local_object(task)
		    trsc = local_peer.local_object(trsc)
		    trsc[task]
		end
	    end
	end
	trsc = Distributed::Transaction.new(plan)
	remote_peer.create_sibling(trsc)

	# Check that marshalling the remote view of a local transaction proxy
	# returns the local proxy itself
	plan.insert(task = Task.new)
	proxy = trsc[task]

	remote_peer.flush # send the updates to the remote peer

	marshalled_remote = remote.marshalled_transaction_proxy(trsc, task)
	assert_equal(proxy, remote_peer.local_object(marshalled_remote))
	assert_equal(marshalled_remote.remote_object, proxy.remote_siblings[remote_peer])
    end

    def test_edition
	peer2peer(true) do |remote|
	    class << remote
		include Test::Unit::Assertions
		def edit_transaction(trsc)
		    trsc = local_peer.local_object(trsc)
		    trsc.edit
		    assert_equal(local_peer, trsc.next_editor)
		    assert(trsc.editor?)
		end
		def give_back(trsc)
		    trsc = local_peer.local_object(trsc)
		    assert(trsc.editor?)
		    trsc.release(false)
		end
	    end
	end

	trsc = Distributed::Transaction.new(plan)
	remote_trsc = remote_peer.create_sibling(trsc)
	trsc.edit

	assert(trsc.editor?)
	assert(!trsc.release(false))

	trsc.add_owner remote_peer
	assert_equal(remote_peer, trsc.next_editor)
	assert(trsc.release(true))

	assert_doesnt_timeout(5) do
	    remote.edit_transaction(trsc)
	end
	assert_raises(NotEditor) { trsc.commit_transaction }
	remote.give_back(trsc)

	assert_doesnt_timeout(5) do
	    trsc.edit
	end
	assert(trsc.edition_reloop)
	assert_raises(NotReady) { trsc.commit_transaction }
    end

    def test_ownership
	peer2peer do |remote|
	    remote.plan.insert(Task.new(:id => 1))
	    def remote.add_owner_local(trsc)
		trsc = local_peer.local_object(trsc)
		trsc.add_owner local_peer
		nil
	    end
	end
	r_task = remote_task(:id => 1)
	assert(!Distributed.owns?(r_task))
	assert(remote_peer.owns?(r_task))

	# Create a transaction for the plan
	trsc = Roby::Distributed::Transaction.new(plan)
	remote_peer.create_sibling(trsc)
	assert(Distributed.owns?(trsc))
	assert(!remote_peer.owns?(trsc))

	trsc.add_owner remote_peer
	assert(remote_peer.owns?(trsc))
	trsc.remove_owner remote_peer
	assert(!remote_peer.owns?(trsc))

	assert_raises(NotOwner) { t_task = trsc[r_task] }
	# Check we still can remove the peer from the transaction owners
	trsc.add_owner(remote_peer)
	r_task = remote_peer.subscribe(r_task)
	t_task = trsc[r_task] 

	assert_raises(OwnershipError) { trsc.remove_owner(remote_peer) }
	trsc.self_owned = false

	task = Task.new
	assert_raises(NotOwner) { t_task.realized_by task }
	assert_raises(NotOwner) { task.realized_by t_task }
	assert_raises(NotOwner) { task.event(:start).on t_task.event(:start) }
	assert_raises(NotOwner) { trsc.discard_transaction }
	assert_raises(NotOwner) { trsc.commit_transaction }
	assert(! task.plan)
	assert_nothing_raised { t_task.event(:start).on task.event(:start) }

	remote.add_owner_local(trsc)

	assert_nothing_raised { t_task.realized_by task }
	assert_nothing_raised { t_task.remove_child task }
	assert_nothing_raised { t_task.event(:start).remove_signal task.event(:start) }
	assert_nothing_raised { task.realized_by t_task }
	assert_nothing_raised { task.event(:start).on t_task.event(:start) }
	assert_raises(OwnershipError) { trsc.remove_owner remote_peer }
	assert_raises(OwnershipError) { trsc.self_owned = false }
	assert_nothing_raised { trsc.discard_transaction }
    end

    def build_transaction(trsc)
	parent = remote_task(:id => 1)
	child  = remote_task(:id => 3)

	# Now, add a task of our own and link the remote and the local
	task = SimpleTask.new :id => 2
	trsc.discover(task)
	trsc.self_owned

	# Check some properties
	assert((trsc[parent].owners - trsc.owners).empty?)
	assert(trsc[parent].read_write?)
	assert(task.read_write?)
	assert(trsc[parent].event(:start).read_write?)
	assert(trsc[parent].event(:stop).read_write?)
	assert(task.event(:start).read_write?)
	assert(task.event(:stop).read_write?)

	parent = remote_peer.subscribe(parent)
	child  = remote_peer.subscribe(child)

	# Add relations
	trsc[parent].realized_by task
	task.realized_by trsc[child]
	trsc[parent].event(:start).on task.event(:start)
	task.event(:stop).on trsc[child].event(:stop)

	[task, parent]
    end

    # Checks that +plan+ looks like the result of #build_transaction
    def check_resulting_plan(plan)
	#assert_equal(4, plan.known_tasks.size)
	r_task = plan.known_tasks.find { |t| t.arguments[:id] == 1 }
	task   = plan.known_tasks.find { |t| t.arguments[:id] == 2 }
	c_task = plan.known_tasks.find { |t| t.arguments[:id] == 3 }

	assert_equal(2, r_task.children.size, r_task.children)
	assert(r_task.child_object?(task, Roby::TaskStructure::Hierarchy))
	assert_equal([task.event(:start)], r_task.event(:start).child_objects(Roby::EventStructure::Signal).to_a)
	assert_equal([c_task], task.children.to_a)
	assert_equal([c_task.event(:stop)], task.event(:stop).child_objects(Roby::EventStructure::Signal).to_a)
	assert(r_task.child_object?(c_task, Roby::TaskStructure::Hierarchy))
    end

    # Commit the transaction and checks the result
    def check_transaction_commit(trsc)
	# Commit the transaction
	assert(trsc.commit_transaction)
	remote.check_plan
	check_resulting_plan(local.plan)
    end

    def test_executed_by
	peer2peer(true) do |remote|
	    task = Task.new(:id => 1) 
	    exec = Class.new(Task) do
		event :ready, :command => true
	    end.new(:id => 'exec')
	    task.executed_by exec
	    remote.plan.insert(task)

	    remote.singleton_class.class_eval do
		define_method(:check_execution_agent) do
		    task.execution_agent == exec
		end
	    end
	end
	r_task = remote_task(:id => 1)
	assert_equal(remote_peer.task, r_task.execution_agent)

	trsc = Roby::Distributed::Transaction.new(plan) 
	trsc.add_owner remote_peer
	trsc.self_owned
	r_task = remote_peer.subscribe(r_task)
	assert_equal(trsc[remote_peer.task], trsc[r_task].execution_agent)
	trsc.propose(remote_peer)
	trsc.commit_transaction

	assert_equal(remote_peer.task, r_task.execution_agent)
	assert(remote.check_execution_agent)
    end

    def test_argument_updates
	peer2peer do |remote|
	    remote.plan.insert(Task.new(:id => 2))
	    def remote.set_argument(task)
		task = local_peer.local_object(task)
		task.arguments[:foo] = :bar
		nil
	    end
	end
	r_task = remote_task(:id => 2)
	assert_raises(NotOwner, r_task.owners) { r_task.arguments[:foo] = :bar }

	trsc   = Roby::Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.self_owned
	trsc.propose(remote_peer)

	t_task = trsc[r_task]
	# fails because we cannot override an argument already set
	assert_raises(NotOwner) { t_task.arguments[:foo] = :bar }

	task = Task.new(:id => 2)
	t_task = trsc[task]
	assert_nothing_raised { remote.set_argument(t_task) }

	remote_peer.flush
	assert_equal(:bar, t_task.arguments[:foo], t_task.name)
    end

    def test_propose_commit
	peer2peer(true) do |remote|
	    testcase = self
	    remote.plan.insert(root = SimpleTask.new(:id => 1))
	    root.realized_by(child = SimpleTask.new(:id => 3))

	    remote.class.class_eval do
		define_method(:check_transaction) do |trsc|
		    testcase.check_resulting_plan(local_peer.local_object(trsc))
		end
		define_method(:check_plan) do
		    testcase.check_resulting_plan(remote.plan)
		end
	    end
	end
	trsc   = Roby::Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.self_owned

	task, r_task = build_transaction(trsc)

	# Send the transaction to remote_peer and commit it
	trsc.propose(remote_peer)
	remote.check_transaction(trsc)

	check_transaction_commit(trsc)
    end

    def test_synchronization
	peer2peer(true) do |remote|
	    testcase = self
	    remote.plan.insert(root = SimpleTask.new(:id => 1))
	    root.realized_by SimpleTask.new(:id => 3)

	    remote.class.class_eval do
		define_method(:check_transaction) do |trsc|
		    testcase.check_resulting_plan(local_peer.local_object(trsc))
		end
		define_method(:check_plan) { testcase.check_resulting_plan(remote.plan) }
		define_method(:check_subscription) do |trsc|
		    trsc = local_peer.local_object(trsc)
		    local_peer.subscribed?(trsc) && local_peer.local.subscribed?(trsc)
		end
	    end
	end

	# Create a transaction for the plan and send it right away
	trsc = Roby::Distributed::Transaction.new(plan)
	trsc.self_owned
	trsc.add_owner remote_peer
	trsc.propose(remote_peer)
	assert(remote_peer.subscribed?(trsc) && remote_peer.local.subscribed?(trsc))
	assert(remote.check_subscription(trsc))

	task, r_task = build_transaction(trsc)

	check_resulting_plan(trsc)
	remote_peer.flush
	remote.check_transaction(trsc)

	# Commit the transaction
	check_transaction_commit(trsc)
    end
end

