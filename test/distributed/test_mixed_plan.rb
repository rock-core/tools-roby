require 'roby/test/distributed'
require 'roby/tasks/simple'

# This testcase tests buildings plans where local tasks are interacting with remote tasks
#
# Naming scheme:
#   test_r<type of remote object>_realizes_l<type of local object>(_dynamic)
#
# For instance,  test_rproxy_realizes_lproxy means that we are building a
# transaction where a remote transaction proxy is linked to a local transaction
# proxy. If _dynamic is appended, #propose is called when the transaction is still
# empty. Otherwise, #propose is called after all modifications have been put into
# the transaction (propose then build or build then propose)
#
# The transaction is always built locally
class TC_DistributedMixedPlan < Minitest::Test
    # Creates in +plan+ a task which is a child in a depends_on relation and a parent
    # in a planned_by relation. All tasks have an ID of "#{name}-#{number}", with
    # 2 for the central task, 1 for its parent task and 3 for its planning task.
    #
    # Returns [-1, -2, -3]
    def add_tasks(plan, name)
	t1, t2, t3 = (1..3).map { |i| Tasks::Simple.new(:id => "#{name}-#{i}") }
	t1.depends_on t2
	t2.planned_by t3
	plan.add_mission(t1)
	plan.add(t2)
	plan.add(t3)

	[t1, t2, t3]
    end

    def check_local_center_structure(node, removed_planner)
	if node.respond_to?(:__getobj__)
	    assert_equal(["remote-2"], node.parents.map { |obj| obj.arguments[:id] })
	else
	    assert_equal(["local-1", "remote-2"].to_set, node.parents.map { |obj| obj.arguments[:id] }.to_set)
	    unless removed_planner
		assert_equal(["local-3"], node.enum_for(:each_planning_task).map { |obj| obj.arguments[:id] })
	    end
	end
    end

    def check_remote_center_structure(node, removed_planner)
	assert_equal(["local-2"], node.children.map { |obj| obj.arguments[:id] })
	unless node.respond_to?(:__getobj__)
	    assert_equal(["remote-1"], node.parents.map { |obj| obj.arguments[:id] })
	    unless removed_planner
		assert_equal(["remote-3"], node.enum_for(:each_planning_task).map { |obj| obj.arguments[:id] })
	    end
	end
    end

    # Checks that +plan+ has all 6 tasks with remote-2 and local-2 linked as
    # expected +plan+ may be either the transaction or the plan
    #
    # Tests are in two parts: first we build the transaction and check the
    # relations of the resulting proxies. Then, we remove all relations of
    # tasks *in the plan*.  Since we have added a depends_on between the
    # central tasks, the depends_on relations are kept inside the transaction.
    # However, this is not the case for planning relations.  Thus, the planning
    # relation does not exist anymore in the transaction after they have been
    # removed from the plan.
    def check_resulting_plan(plan, removed_planner)
	assert(remote_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "remote-2" }, plan.known_tasks)
	check_remote_center_structure(remote_center_node, removed_planner)
	assert(local_center_node  = plan.known_tasks.find { |t| t.arguments[:id] == "local-2" }, plan.known_tasks)
	check_local_center_structure(local_center_node, removed_planner)
    end

    def assert_cleared_relations(plan)
	if remote_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "remote-2" }
	    assert_equal([], remote_center_node.enum_for(:each_planning_task).to_a)
	end

	if local_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "local-2" }
	    assert_equal([], local_center_node.enum_for(:each_planning_task).to_a)
	end
    end

    # Common setup of the remote peer
    def common_setup(propose_first)
	peer2peer do |remote|
	    testcase = self
	    remote.singleton_class.class_eval do
		define_method(:add_tasks) do |plan|
		    plan = local_peer.proxy(plan)
		    plan.edit do
			testcase.add_tasks(plan, "remote") 
		    end
		end
		define_method(:check_resulting_plan) do |plan, removed_planner|
		    plan = local_peer.proxy(plan)
		    plan.edit do
			testcase.check_resulting_plan(local_peer.proxy(plan), removed_planner) 
		    end
		end
		define_method(:assert_cleared_relations) do |plan|
		    plan = local_peer.proxy(plan)
		    plan.edit do
			testcase.assert_cleared_relations(local_peer.proxy(plan))
		    end
		end
		def remove_relations(t2)
		    plan.edit do
			t2 = local_peer.local_object(t2)
			raise unless t3 = t2.planning_task
			t2.remove_planning_task(t3)
		    end
		end
		def subscribe(remote_task)
		    local_peer.subscribe(remote_task)
		end
	    end
	end

	# Create the transaction, and do the necessary modifications
	trsc = Distributed::Transaction.new(plan)

	trsc.add_owner remote_peer
	trsc.self_owned
	trsc.propose(remote_peer) if propose_first

	yield(trsc)

	# Check the transaction is still valid, regardless of the
	# changes we made to the plan
	check_resulting_plan(trsc, true)
	trsc.release(false)
	remote.check_resulting_plan(Distributed.format(trsc), true)
	trsc.edit

	# Commit and check the result
	trsc.commit_transaction

	check_resulting_plan(plan, true)
	remote.check_resulting_plan(Distributed.format(plan), true)
    end

    def test_rproxy_realizes_lproxy(propose_first = false)
	common_setup(propose_first) do |trsc|
	    # First, add relations between two nodes that are already existing
	    remote.add_tasks(Distributed.format(plan))
	    r_t2 = subscribe_task(:id => 'remote-2')
	    assert(1, r_t2.parents.to_a.size)
	    r_t1 = r_t2.parents.find { true }
	    t1, t2, t3 = Roby.synchronize { add_tasks(plan, "local") }

	    assert(plan.useful_task?(r_t1))
	    trsc[r_t2].depends_on trsc[t2]
	    trsc[r_t2].signals(:start, trsc[t2], :start)
	    assert(plan.useful_task?(r_t1))
	    check_resulting_plan(trsc, false)
	    if propose_first
		trsc.release(false)
		remote.check_resulting_plan(Distributed.format(trsc), false)
		trsc.edit
	    end

	    # Remove the relations in the real tasks (not the proxies)
	    Roby.synchronize do
		t2.remove_planning_task(t3)
	    end
	    remote.remove_relations(Distributed.format(r_t2))
	    remote.subscribe(Distributed.format(t2))

	    process_events
	    assert(plan.useful_task?(r_t1))
	    assert_cleared_relations(plan)

	    unless propose_first
		trsc.propose(remote_peer)
	    end

	    process_events
	    remote.assert_cleared_relations(Distributed.format(plan))
	end
    end
    def test_rproxy_realizes_lproxy_dynamic; test_rproxy_realizes_lproxy(true) end

    def test_rproxy_realizes_ltask(propose_first = false)
	common_setup(propose_first) do |trsc|
	    remote.add_tasks(Distributed.format(plan))
	    r_t2 = subscribe_task(:id => 'remote-2')
	    t1, t2, t3 = Roby.synchronize { add_tasks(trsc, "local") }

	    trsc[r_t2].depends_on t2
	    trsc[r_t2].signals(:start, t2, :start)
	    check_resulting_plan(trsc, false)
	    process_events
	    if propose_first
		remote_peer.push_subscription(t2)
		trsc.release(false)
		remote.check_resulting_plan(Distributed.format(trsc), false)
		trsc.edit
	    end

	    # remove the relations in the real tasks (not the proxies)
	    remote.remove_relations(Distributed.format(r_t2))

	    unless propose_first
		trsc.propose(remote_peer)
		remote_peer.push_subscription(t2)
	    end
	    process_events
	    remote.assert_cleared_relations(Distributed.format(plan))
	end
    end
    def test_rproxy_realizes_ltask_dynamic; test_rproxy_realizes_ltask(true) end

    # no non-dynamic version for that since we need the transactio to be
    # present on both sides if we want to have remote tasks in it
    def test_rtask_realizes_lproxy
	common_setup(true) do |trsc|
	    trsc.release(false)
	    r_t1, r_t2, r_t3 = remote.add_tasks(Distributed.format(trsc)).map { |t| remote_peer.proxy(t) }
	    trsc.edit

	    assert(r_t2.subscribed?)
	    t1, t2, t3 = Roby.synchronize { add_tasks(plan, "local") }
	    r_t2.depends_on trsc[t2]
	    r_t2.signals(:start, trsc[t2], :start)
	    remote_peer.subscribe(r_t2)
	    remote_peer.push_subscription(t2)

	    check_resulting_plan(trsc, false)
	    trsc.release(false)
	    remote.check_resulting_plan(Distributed.format(trsc), false)
	    trsc.edit

	    # remove the relations in the real tasks (not the proxies)
	    t2.remove_planning_task(t3)
	    process_events
	    remote.assert_cleared_relations(Distributed.format(plan))
	end
    end

    def test_garbage_collect
	peer2peer do |remote|
	    remote.plan.add_mission(Tasks::Simple.new(:id => 'remote-1'))
	    def remote.insert_children(trsc, root_task)
		trsc = local_peer.local_object(trsc)
		root_task = local_peer.local_object(root_task)
		trsc.edit

		root_task.depends_on(r2 = Tasks::Simple.new(:id => 'remote-2'))
		r2.depends_on(r3 = Tasks::Simple.new(:id => 'remote-3'))
		trsc.release(false)
	    end
	end

	r1 = subscribe_task(:id => 'remote-1')
	assert(!plan.unneeded_tasks.include?(r1))

	t1 = Tasks::Simple.new

	# Add a local child to r1. This local child, and r1, must be kept event
	# we are not subscribed to r1 anymore
	trsc = Distributed::Transaction.new(plan)
	trsc.add_owner(remote_peer)
	trsc[r1].depends_on t1
	Roby.synchronize do
	    remote_peer.unsubscribe(r1)
	    assert(!plan.unneeded_tasks.include?(r1))
	end

	trsc.propose(remote_peer)
	trsc.commit_transaction
	assert(!plan.unneeded_tasks.include?(r1))
	assert(!plan.unneeded_tasks.include?(t1), plan.unneeded_tasks)

	# Ok, we now create a r1 => t1 => t2 => t3 chain
	#   * t2 and t3 are kept because they are useful for r1
	t2, t3 = nil
	Roby.synchronize do
	    t1.depends_on(t2 = Tasks::Simple.new)
	    assert(!plan.unneeded_tasks.include?(t2))
	    t2.depends_on(t3 = Tasks::Simple.new)
	    assert(!plan.unneeded_tasks.include?(t3))
	end

	# Now, create a t3 => r2 => r3 chain
	# * r2 should be kept since it is related to a task which is kept
	# * r3 should not be kept
	trsc = Distributed::Transaction.new(plan)
	trsc.add_owner(remote_peer)
	trsc.propose(remote_peer)
	trsc.release
	remote.insert_children(Distributed.format(trsc), Distributed.format(trsc[t3]))
	trsc.edit
	trsc.commit_transaction
	process_events

	r2 = remote_task(:id => 'remote-2')
	Roby.synchronize do
	    assert(r2.plan && !plan.unneeded_tasks.include?(r2))
	    assert(t3.child_object?(r2, TaskStructure::Hierarchy))
	end

	r3 = remote_task(:id => 'remote-3')
	Roby.synchronize do
	    assert(!r3.plan || plan.unneeded_tasks.include?(r3))
	end
    end

    # This tests that the race condition between transaction commit and plan GC
    # is handled properly: if a task inside a transaction will be GCed just
    # after the commit, there is a race condition possibility if the other
    # peers do not have committed the transaction yet
    def test_commit_race_condition
	peer2peer do |remote|
	    def remote.add_task(trsc)
		trsc = local_peer.local_object(trsc)
		trsc.edit
		trsc.add(Tasks::Simple.new(:id => 'remote'))
		trsc.release(false)
	    end
	end
	
	# Create an empty transaction and send it to our peer
	# The peer will then add a task, which 
	# will be GCed as soon as the transaction is committed
	trsc = Distributed::Transaction.new(plan)
	trsc.add_owner(remote_peer)
	trsc.propose(remote_peer)
	trsc.release
	remote.add_task(Distributed.format(trsc))
	trsc.edit
	
        trsc.commit_transaction
        process_events
	assert(remote_peer.connected?)
    end
end


