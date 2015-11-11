require 'roby/test/distributed'
require 'roby/tasks/simple'

class TC_DistributedTransaction < Minitest::Test
    def test_marshal_transactions
	peer2peer do |remote|
	    PeerServer.class_eval do
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

	trsc = remote_peer.call(:transaction)
	assert_kind_of(Plan::DRoby, trsc)
	assert_equal(local.plan, remote_peer.local_object(trsc))

	dtrsc = remote_peer.call(:d_transaction)
	assert_kind_of(Distributed::Transaction::DRoby, dtrsc)
	assert_raises(InvalidRemoteOperation) { remote_peer.local_object(dtrsc) }
    end

    def test_transaction_create
	peer2peer do |remote|
	    PeerServer.class_eval do
		include Minitest::Assertions
		def check_transaction(marshalled_trsc, trsc_drbobject)
		    assert(trsc = peer.local_object(marshalled_trsc))
		    assert_equal(trsc_drbobject, trsc.remote_siblings[peer])
		    assert_equal([peer, Roby::Distributed], trsc.owners)
		    assert(!trsc.first_editor?)
		    assert(!trsc.editor?)

		    assert(trsc.subscribed?)
		    assert(trsc.update_on?(peer))
		    assert(trsc.updated_by?(peer))
		    trsc
		end
	    end
	end
	trsc = Distributed::Transaction.new(plan)
	assert(trsc.self_owned?)
	assert(trsc.first_editor?)
	assert(trsc.editor?)

	remote_peer.create_sibling(trsc)
	trsc.add_owner remote_peer
	assert_equal([Distributed, remote_peer], trsc.owners)
	remote_peer.call(:check_transaction, trsc, trsc.remote_id)
	assert(trsc.subscribed?)
	assert(trsc.update_on?(remote_peer))
	assert(trsc.updated_by?(remote_peer))

	assert(trsc.editor?)
    end

    def test_transaction_proxies
	peer2peer do |remote|
	    PeerServer.class_eval do
		include Minitest::Assertions
		def marshalled_transaction_proxy(trsc, task)
		    task = peer.local_object(task)
		    trsc = peer.local_object(trsc)
		    proxy = trsc[task]

		    assert(proxy.update_on?(peer))
		    assert(proxy.updated_by?(peer))
		    proxy
		end
	    end
	end
	trsc = Distributed::Transaction.new(plan)
	remote_peer.create_sibling(trsc)

	# Check that marshalling the remote view of a local transaction proxy
	# returns the local proxy itself
	plan.add_mission(task = Task.new)
	assert(!plan.update_on?(remote_peer))
	assert(trsc.update_on?(remote_peer))
	assert(!task.update_on?(remote_peer))

	proxy = trsc[task]
	assert(task.update_on?(remote_peer))
	assert(proxy.update_on?(remote_peer))
	assert(proxy.updated_by?(remote_peer))
	process_events

	assert(marshalled_remote = remote_peer.call(:marshalled_transaction_proxy, trsc, task))
	assert_equal(proxy, remote_peer.local_object(marshalled_remote))
    end

    # Checks that if we add a set of tasks, then their relations are updated as well
    def test_discover
	peer2peer do |remote|
	    def remote.add_tasks(trsc)
		trsc = local_peer.local_object(trsc)

		trsc.edit do
		    t1 = Tasks::Simple.new :id => 'root'
		    t1.depends_on(t2 = Tasks::Simple.new(:id => 'child'))
		    t1.signals(:start, t2, :start)
		    t2.depends_on(t3 = Tasks::Simple.new(:id => 'grandchild'))
		    t3.signals(:failed, t2, :failed)

		    trsc.add_mission(t1)
		end
	    end
	end

	trsc = Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.propose(remote_peer)

	trsc.release(false)
	remote.add_tasks(Distributed.format(trsc))
	trsc.edit
	assert(t1 = trsc.find_tasks.with_arguments(:id => 'root').to_a.first)
	assert(t2 = trsc.find_tasks.with_arguments(:id => 'child').to_a.first)
	assert(t3 = trsc.find_tasks.with_arguments(:id => 'grandchild').to_a.first)

	assert(t1.child_object?(t2, TaskStructure::Dependency))
	assert(t2.child_object?(t3, TaskStructure::Dependency))
    end

    def test_edition
	peer2peer do |remote|
	    class << remote
		include Minitest::Assertions
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
	    remote.edit_transaction(Distributed.format(trsc))
	end
	assert_raises(NotEditor) { trsc.commit_transaction }
	remote.give_back(Distributed.format(trsc))

	assert_doesnt_timeout(5) do
	    trsc.edit
	end
	assert(trsc.edition_reloop)
	assert_raises(NotReady) { trsc.commit_transaction }
    end

    def test_ownership
	peer2peer do |remote|
	    remote.plan.add_mission(Task.new(:id => 1))
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
	assert_raises(OwnershipError) { t_task = trsc[r_task] }
	# Check we still can remove the peer from the transaction owners
	trsc.add_owner(remote_peer)
	t_task = trsc[r_task]

	assert_raises(OwnershipError) { trsc.remove_owner(remote_peer) }
	trsc.self_owned = false

	task = Task.new
	assert_raises(OwnershipError) { t_task.depends_on task }
	assert_raises(OwnershipError) { task.depends_on t_task }
	assert_raises(OwnershipError) { task.event(:start).signals t_task.event(:start) }
	assert_raises(OwnershipError) { trsc.discard_transaction }
	assert_raises(OwnershipError) { trsc.commit_transaction }
	assert(! task.plan)
	t_task.signals(:start, task, :start)

	remote.add_owner_local(Distributed.format(trsc))

	t_task.depends_on task
	t_task.remove_child task
	t_task.event(:start).remove_signal task.event(:start)
	task.depends_on t_task
	task.signals(:start, t_task, :start)
	assert_raises(OwnershipError) { trsc.remove_owner remote_peer }
	assert_raises(OwnershipError) { trsc.self_owned = false }
	trsc.discard_transaction
    end

    def test_executed_by
	peer2peer do |remote|
	    task = Task.new(:id => 1) 
	    exec = Task.new_submodel do
		event :ready, :command => true
	    end.new(:id => 'exec')
	    task.executed_by exec
	    remote.plan.add_mission(task)

	    remote.singleton_class.class_eval do
		include Minitest::Assertions
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

    class ArgumentUpdateTest < Roby::Task
	arguments :foo
    end

    def test_argument_updates
	peer2peer do |remote|
	    remote.plan.add_mission(ArgumentUpdateTest.new(:id => 2))
	    def remote.set_argument(task)
		task = local_peer.local_object(task)
		task.plan.edit
		task.arguments[:foo] = :bar
		task.plan.release(false)
		nil
	    end
	end
	r_task = remote_task(:id => 2, :permanent => true)
	assert_raises(OwnershipError, r_task.owners) { r_task.arguments[:foo] = :bar }

	trsc   = Roby::Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.self_owned
	trsc.propose(remote_peer)

	t_task = trsc[r_task]
	trsc.release(false)
	remote.set_argument(Distributed.format(t_task))

	trsc.edit
	assert_equal(:bar, t_task.arguments[:foo], t_task.name)
	assert(!t_task.arguments.writable?(:foo))
	assert_raises(ArgumentError) { t_task.arguments[:foo] = :blo }
	trsc.commit_transaction
	assert_equal(:bar, r_task.arguments[:foo])
    end

    def build_transaction(trsc)

	# Now, add a task of our own and link the remote and the local
	task = Tasks::Simple.new :id => 'local'
	trsc.add(task)

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
	trsc[parent].depends_on task
	task.depends_on trsc[child]
	trsc[parent].event(:start).signals task.event(:start)
	task.event(:stop).signals trsc[child].event(:stop)

	[task, parent]
    end

    # Checks that +plan+ looks like the result of #build_transaction
    def check_resulting_plan(plan)
	#assert_equal(4, plan.known_tasks.size)
	r_task = plan.known_tasks.find { |t| t.arguments[:id] == 'remote-1' }
	task   = plan.known_tasks.find { |t| t.arguments[:id] == 'local' }
	c_task = plan.known_tasks.find { |t| t.arguments[:id] == 'remote-2' }

	assert_equal(2, r_task.children.to_a.size, r_task.children)
	assert(r_task.child_object?(task, Roby::TaskStructure::Dependency))
	assert_equal([task.event(:start)], r_task.event(:start).child_objects(Roby::EventStructure::Signal).to_a)
	assert_equal([c_task], task.children.to_a)
	assert_equal([c_task.event(:stop)], task.event(:stop).child_objects(Roby::EventStructure::Signal).to_a)
	assert(r_task.child_object?(c_task, Roby::TaskStructure::Dependency))
    end

    # Commit the transaction and checks the result
    def check_transaction_commit(trsc)
	# Commit the transaction
	assert(trsc.commit_transaction)
	remote_peer.call(:check_plan)
	check_resulting_plan(local.plan)
    end

    def test_propose_commit
	peer2peer do |remote|
	    testcase = self
	    remote.plan.add_mission(root = Tasks::Simple.new(:id => 'remote-1'))
	    root.depends_on(child = Tasks::Simple.new(:id => 'remote-2'))

	    PeerServer.class_eval do
		include Minitest::Assertions
		define_method(:check_transaction) do |trsc|
		    trsc = peer.local_object(trsc)
		    testcase.check_resulting_plan(trsc)
		end
		define_method(:check_plan) do
		    testcase.check_resulting_plan(plan)
		end
	    end
	end
	trsc   = Roby::Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.self_owned

	task, r_task = build_transaction(trsc)

	# Send the transaction to remote_peer and commit it
	trsc.propose(remote_peer)

	remote_peer.call(:check_transaction, trsc)
	check_resulting_plan(trsc)

	check_transaction_commit(trsc)
    end

    def test_synchronization
	peer2peer do |remote|
	    testcase = self
	    remote.plan.add_mission(root = Tasks::Simple.new(:id => 'remote-1'))
	    root.depends_on Tasks::Simple.new(:id => 'remote-2')

	    PeerServer.class_eval do
		define_method(:check_transaction) do |trsc|
		    testcase.check_resulting_plan(peer.local_object(trsc))
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
	remote_peer.call(:check_transaction, trsc)

	# Commit the transaction
	check_transaction_commit(trsc)
    end

    class RemoteTaskModel < Tasks::Simple
        argument :arg
    end

    def test_create_remote_tasks
	peer2peer do |remote|
	    def remote.arguments_of(t)
		t = local_peer.local_object(t)
		t.arguments
	    end

	    def remote.check_ownership(t)
		t = local_peer.local_object(t)
		t.self_owned?
	    end

	    def remote.check_mission(t)
		t = local_peer.local_object(t)
		plan.mission?(t)
	    end
	end

	trsc = Roby::Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.propose(remote_peer)

	local_task = Tasks::Simple.new(:id => 'local')
	trsc.add_mission(local_task)

	t = RemoteTaskModel.new(:arg => 10, :id => 0)
	t.extend DistributedObject
	local_task.depends_on t
	trsc.add_mission(t)
	t.owner = remote_peer

	assert(trsc.task_index.by_owner[remote_peer].include?(t))
	assert(!trsc.task_index.by_owner[Roby::Distributed].include?(t))

	assert(!t.self_owned?)
	assert(remote.check_ownership(Distributed.format(t)))

	trsc.commit_transaction
	assert(plan.include?(t))
	assert(!plan.mission?(t))
	assert(!t.self_owned?)
	assert(plan.task_index.by_owner[remote_peer].include?(t), plan.task_index.by_owner)
	assert(!plan.task_index.by_owner[Roby::Distributed].include?(t))
	assert(remote.check_mission(Distributed.format(t)))
	assert(remote.check_ownership(Distributed.format(t)))
	assert(local_task.children.include?(t))
	assert_equal({ :arg => 10, :id => 0 }, remote.arguments_of(Distributed.format(t)))
    end
end

