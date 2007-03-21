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
	assert_raises(InvalidRemoteOperation) { remote_peer.local_object(dtrsc) }
    end

    def test_transaction_create
	peer2peer(true) do |remote|
	    class << remote
		include Test::Unit::Assertions
		def check_transaction(marshalled_trsc, trsc_drbobject)
		    assert(trsc = local_peer.local_object(marshalled_trsc))
		    assert_equal(trsc_drbobject, trsc.remote_siblings[local_peer])
		    assert_equal([local_peer, Roby::Distributed], trsc.owners)
		    assert(!trsc.first_editor?)
		    assert(!trsc.editor?)
		    assert(trsc.conflict_solver.kind_of?(Roby::SolverIgnoreUpdate))

		    assert(trsc.subscribed?)
		    assert(trsc.update_on?(local_peer))
		    assert(trsc.updated_by?(local_peer))
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
	remote.check_transaction(trsc, trsc.remote_id)
	assert(trsc.subscribed?)
	assert(trsc.update_on?(remote_peer))
	assert(trsc.updated_by?(remote_peer))

	assert(trsc.editor?)
    end

    def test_transaction_proxies
	peer2peer(true) do |remote|
	    class << remote
		include Test::Unit::Assertions
		def marshalled_transaction_proxy(trsc, task)
		    task = local_peer.local_object(task)
		    trsc = local_peer.local_object(trsc)
		    proxy = trsc[task]

		    assert(proxy.update_on?(local_peer))
		    assert(proxy.updated_by?(local_peer))
		    proxy
		end
	    end
	end
	trsc = Distributed::Transaction.new(plan)
	remote_peer.create_sibling(trsc)

	# Check that marshalling the remote view of a local transaction proxy
	# returns the local proxy itself
	plan.insert(task = Task.new)
	assert(!plan.update_on?(remote_peer))
	assert(!task.update_on?(remote_peer))

	proxy = trsc[task]
	assert(task.update_on?(remote_peer))
	assert(proxy.update_on?(remote_peer))
	assert(proxy.updated_by?(remote_peer))
	process_events

	assert(marshalled_remote = remote.marshalled_transaction_proxy(trsc, task))
	assert_equal(proxy, remote_peer.local_object(marshalled_remote))
    end

    # Checks that if we discover a set of tasks, then their relations are updated as well
    def test_discover
	peer2peer(true) do |remote|
	    def remote.add_tasks(trsc)
		trsc = local_peer.local_object(trsc)
		trsc.edit
		t1 = SimpleTask.new :id => 'root'
		t1.realized_by(t2 = SimpleTask.new(:id => 'child'))
		t1.on(:start, t2, :start)
		t2.realized_by(t3 = SimpleTask.new(:id => 'grandchild'))
		t3.on(:failed, t2, :failed)

		trsc.insert(t1)
		trsc.release(false)
	    end
	end

	trsc = Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.propose(remote_peer)

	trsc.release(false)
	remote.add_tasks(trsc)
	trsc.edit
	assert(t1 = trsc.find_tasks.with_arguments(:id => 'root').to_a.first)
	assert(t2 = trsc.find_tasks.with_arguments(:id => 'child').to_a.first)
	assert(t3 = trsc.find_tasks.with_arguments(:id => 'grandchild').to_a.first)

	assert(t1.child_object?(t2, TaskStructure::Hierarchy))
	assert(t2.child_object?(t3, TaskStructure::Hierarchy))
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
	peer2peer(true) do |remote|
	    remote.plan.insert(Task.new(:id => 1))
	    def remote.add_owner_local(trsc)
		trsc = local_peer.local_object(trsc)
		trsc.add_owner local_peer
		nil
	    end
	end

	# Create a transaction for the plan
	trsc = Roby::Distributed::Transaction.new(plan)
	remote_peer.create_sibling(trsc)
	assert(Distributed.owns?(trsc))
	assert(!remote_peer.owns?(trsc))

	trsc.add_owner remote_peer
	assert(remote_peer.owns?(trsc))
	trsc.remove_owner remote_peer
	assert(!remote_peer.owns?(trsc))

	r_task = subscribe_task(:id => 1)
	assert(!Distributed.owns?(r_task))
	assert(remote_peer.owns?(r_task))
	assert_raises(NotOwner) { t_task = trsc[r_task] }
	# Check we still can remove the peer from the transaction owners
	trsc.add_owner(remote_peer)
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

    def test_executed_by
	peer2peer(true) do |remote|
	    task = Task.new(:id => 1) 
	    exec = Class.new(Task) do
		event :ready, :command => true
	    end.new(:id => 'exec')
	    task.executed_by exec
	    remote.plan.insert(task)

	    remote.singleton_class.class_eval do
		include Test::Unit::Assertions
		define_method(:check_execution_agent) do
		    remote_connection_tasks = plan.find_tasks.
			with_model(ConnectionTask).
			with_arguments(:peer => Roby::Distributed).
			to_a
		    assert(remote_connection_tasks.empty?)
		    assert_equal(exec, task.execution_agent)
		end
	    end
	end
	r_task = remote_task(:id => 1)
	assert_equal(remote_peer.task, r_task.execution_agent)

	trsc = Roby::Distributed::Transaction.new(plan) 
	trsc.add_owner remote_peer
	trsc.self_owned
	r_task = subscribe_task(:id => 1)
	assert(!trsc[remote_peer.task].distribute?)
	assert_equal(trsc[remote_peer.task], trsc[r_task].execution_agent)
	trsc.propose(remote_peer)
	trsc.commit_transaction

	assert_equal(remote_peer.task, r_task.execution_agent)
	remote.check_execution_agent
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

	process_events
	assert_equal(:bar, t_task.arguments[:foo], t_task.name)
    end

    def build_transaction(trsc)

	# Now, add a task of our own and link the remote and the local
	task = SimpleTask.new :id => 'local'
	trsc.discover(task)

	parent = subscribe_task(:id => 'remote-1')
	child  = subscribe_task(:id => 'remote-2')

	# Check some properties
	assert((trsc[parent].owners - trsc.owners).empty?)
	assert(trsc[parent].read_write?)
	assert(task.read_write?)
	assert(trsc[parent].event(:start).read_write?)
	assert(trsc[parent].event(:stop).read_write?)
	assert(task.event(:start).read_write?)
	assert(task.event(:stop).read_write?)

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
	r_task = plan.known_tasks.find { |t| t.arguments[:id] == 'remote-1' }
	task   = plan.known_tasks.find { |t| t.arguments[:id] == 'local' }
	c_task = plan.known_tasks.find { |t| t.arguments[:id] == 'remote-2' }

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

    def test_propose_commit
	peer2peer(true) do |remote|
	    testcase = self
	    remote.plan.insert(root = SimpleTask.new(:id => 'remote-1'))
	    root.realized_by(child = SimpleTask.new(:id => 'remote-2'))

	    remote.class.class_eval do
		include Test::Unit::Assertions
		define_method(:check_transaction) do |trsc|
		    trsc = local_peer.local_object(trsc)
		    testcase.check_resulting_plan(trsc)
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
	check_resulting_plan(trsc)

	check_transaction_commit(trsc)
    end

    def test_synchronization
	peer2peer(true) do |remote|
	    testcase = self
	    remote.plan.insert(root = SimpleTask.new(:id => 'remote-1'))
	    root.realized_by SimpleTask.new(:id => 'remote-2')

	    remote.class.class_eval do
		define_method(:check_transaction) do |trsc|
		    testcase.check_resulting_plan(local_peer.local_object(trsc))
		end
		define_method(:check_plan) { testcase.check_resulting_plan(remote.plan) }
	    end
	end

	# Create a transaction for the plan and send it right away
	trsc = Roby::Distributed::Transaction.new(plan)
	trsc.self_owned
	trsc.add_owner remote_peer
	trsc.propose(remote_peer)

	task, r_task = build_transaction(trsc)

	check_resulting_plan(trsc)
	process_events
	remote.check_transaction(trsc)

	# Commit the transaction
	check_transaction_commit(trsc)
    end
end

