$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'

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
class TC_DistributedMixedPlan < Test::Unit::TestCase
    include Roby::Distributed::Test

    # Creates in +plan+ a task which is a child in a realized_by relation and a parent
    # in a planned_by relation. All tasks have an ID of "#{name}-#{number}", with
    # 2 for the central task, 1 for its parent task and 3 for its planning task.
    #
    # Returns [-1, -2, -3]
    def add_tasks(plan, name)
	t1, t2, t3 = (1..3).map { |i| SimpleTask.new(:id => "#{name}-#{i}") }
	t1.realized_by t2
	t2.planned_by t3
	plan.insert(t1)
	plan.discover(t2)
	plan.discover(t3)

	[t1, t2, t3]
    end

    # Checks that +plan+ has all 6 tasks with remote-2 and local-2 linked as
    # expected +plan+ may be either the transaction or the plan
    #
    # Tests are in two parts: first we build the transaction and check the
    # relations of the resulting proxies. Then, we remove all relations of
    # tasks *in the plan*.  Since we have added a realized_by between the
    # central tasks, the realized_by relations are kept inside the transaction.
    # However, this is not the case for planning relations.  Thus, the planning
    # relation does not exist anymore in the transaction after they have been
    # removed from the plan.
    def check_resulting_plan(plan, removed_planner)
	assert(remote_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "remote-2" }, plan.known_tasks)
	assert(local_center_node  = plan.known_tasks.find { |t| t.arguments[:id] == "local-2" }, plan.known_tasks)

	assert_equal(["remote-1"], remote_center_node.parents.map { |obj| obj.arguments[:id] })
	assert_equal(["local-1", "remote-2"].to_set, local_center_node.parents.map { |obj| obj.arguments[:id] }.to_set)

	unless removed_planner
	    assert_equal(["remote-3"], remote_center_node.enum_for(:each_planning_task).map { |obj| obj.arguments[:id] })
	    assert_equal(["local-3"], local_center_node.enum_for(:each_planning_task).map { |obj| obj.arguments[:id] })
	end
    end
    def assert_cleared_relations(plan)
	if remote_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "remote-2" }
	    assert_equal([], remote_center_node.parents.to_a)
	    assert_equal([], remote_center_node.enum_for(:each_planning_task).to_a)
	end

	if local_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "local-2" }
	    assert_equal([], local_center_node.parents.to_a)
	    assert_equal([], local_center_node.enum_for(:each_planning_task).to_a)
	end
    end

    # Common setup of the remote peer
    def common_setup(propose_first)
	peer2peer(true) do |remote|
	    testcase = self
	    remote.singleton_class.class_eval do
		define_method(:add_tasks) do |plan|
		    begin
			plan = local_peer.proxy(plan)
			if plan.respond_to?(:edit)
			    plan.edit
			end
			Roby::Control.synchronize do
			    testcase.add_tasks(plan, "remote") 
			end

		    ensure
			if plan.respond_to?(:edit)
			    plan.release(false)
			end
		    end
		end
		define_method(:check_resulting_plan) do |plan, removed_planner|
		    Roby::Control.synchronize do
			testcase.check_resulting_plan(local_peer.proxy(plan), removed_planner) 
		    end
		end
		define_method(:assert_cleared_relations) do |plan|
		    Roby::Control.synchronize do
			testcase.assert_cleared_relations(local_peer.proxy(plan))
		    end
		end
		def remove_relations(t1, t2, t3)
		    Roby::Control.synchronize do
			t1 = local_peer.local_object(t1)
			t2 = local_peer.local_object(t2)
			t3 = local_peer.local_object(t3)
			t1.remove_child(t2)
			t2.remove_planning_task(t3)
		    end
		end
	    end
	end

	# Create the transaction, and do the necessary modifications
	trsc = Distributed::Transaction.new(plan, :conflict_solver => SolverIgnoreUpdate.new)

	trsc.add_owner remote_peer
	trsc.self_owned
	trsc.propose(remote_peer) if propose_first

	yield(trsc)

	assert_happens do
	    # Check the transaction is still valid, regardless of the
	    # changes we made to the plan
	    check_resulting_plan(trsc, true)
	    remote.check_resulting_plan(trsc, true)
	end

	# Commit and check the result
	trsc.commit_transaction

	check_resulting_plan(plan, true)
	remote.check_resulting_plan(plan, true)
    end

    def test_rproxy_realizes_lproxy(propose_first = false)
	# Roby.logger.level = Logger::DEBUG
	common_setup(propose_first) do |trsc|
	    # First, add relations between two nodes that are already existing
	    r_t1, r_t2, r_t3 = remote.add_tasks(plan).map do |t| 
		Control.synchronize { remote_peer.local_object(t) }
	    end
	    t1, t2, t3 = nil
	    Control.synchronize { t1, t2, t3 = add_tasks(plan, "local") }

	    r_t2 = remote_peer.subscribe(r_t2)
	    trsc[r_t2].realized_by trsc[t2]
	    check_resulting_plan(trsc, false)
	    remote_peer.flush
	    remote.check_resulting_plan(trsc, false) if propose_first

	    # Remove the relations in the real tasks (not the proxies)
	    Control.synchronize do
		t1.remove_child(t2)
		t2.remove_planning_task(t3)
	    end
	    remote.remove_relations(r_t1, r_t2, r_t3)

	    assert_happens do
		assert_cleared_relations(plan)
	    end

	    unless propose_first
		trsc.propose(remote_peer)
	    end
	    assert_happens do
		remote.assert_cleared_relations(plan)
	    end
	end
    end
    def test_rproxy_realizes_lproxy_dynamic; test_rproxy_realizes_lproxy(true) end

    def test_rproxy_realizes_ltask(propose_first = false)
	common_setup(propose_first) do |trsc|
	    r_t1, r_t2, r_t3 = remote.add_tasks(plan).map do |t| 
		Control.synchronize { remote_peer.local_object(t) }
	    end
	    t1, t2, t3 = nil
	    Control.synchronize { t1, t2, t3 = add_tasks(trsc, "local") }
	    r_t2 = remote_peer.subscribe(r_t2)

	    trsc[r_t2].realized_by t2
	    assert_happens do
		check_resulting_plan(trsc, false)
		remote.check_resulting_plan(trsc, false) if propose_first
	    end

	    # remove the relations in the real tasks (not the proxies)
	    r_t1.remote_object(remote_peer).remove_child(r_t2.remote_object(remote_peer))
	    r_t2.remote_object(remote_peer).remove_planning_task(r_t3.remote_object(remote_peer))

	    unless propose_first
		trsc.propose(remote_peer)
	    end
	    assert_happens do
		remote.assert_cleared_relations(plan)
	    end
	end
    end
    def test_rproxy_realizes_ltask_dynamic; test_rproxy_realizes_ltask(true) end

    # no non-dynamic version for that since we need the transactio to be
    # present on both sides if we want to have remote tasks in it
    def test_rtask_realizes_lproxy
	common_setup(true) do |trsc|
	    trsc.release(false)
	    r_t1, r_t2, r_t3 = remote.add_tasks(trsc).map { |t| remote_peer.proxy(t) }

	    trsc.edit
	    t1, t2, t3 = nil
	    Control.synchronize do
		t1, t2, t3 = add_tasks(plan, "local")
	    end
	    r_t2.realized_by trsc[t2]

	    check_resulting_plan(trsc, false)
	    remote_peer.flush
	    remote.check_resulting_plan(trsc, false)

	    # remove the relations in the real tasks (not the proxies)
	    t1.remove_child(t2)
	    t2.remove_planning_task(t3)
	    remote_peer.flush
	    remote.assert_cleared_relations(plan)
	end
    end
end


