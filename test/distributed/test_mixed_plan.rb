$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'distributed/common.rb'
require 'roby/distributed/transaction'
require 'mockups/tasks'

# This testcase tests behaviour of plans with both remote and local tasks
# interacting with each other
class TC_DistributedMixedPlan < Test::Unit::TestCase
    include DistributedTestCommon

    def add_tasks(plan, name)
	t1, t2, t3 = (1..3).map { |i| SimpleTask.new(:id => "#{name}-#{i}") }
	t1.realized_by t2
	t2.planned_by t3
	plan.insert(t1)

	[t1, t2, t3]
    end
    def check_resulting_plan(plan)
	remote_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "remote-2" }
	local_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "local-2" }

	assert_equal(["remote-1"], remote_center_node.parents.map { |obj| obj.arguments[:id] })
	assert_equal(["remote-3"], remote_center_node.enum_for(:each_planning_task).map { |obj| obj.arguments[:id] })
	assert_equal(["local-1", "remote-2"].to_set, local_center_node.parents.map { |obj| obj.arguments[:id] }.to_set)
	assert_equal(["local-3"], local_center_node.enum_for(:each_planning_task).map { |obj| obj.arguments[:id] })
    end
    def assert_cleared_relations(plan)
	remote_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "remote-2" }
	local_center_node = plan.known_tasks.find { |t| t.arguments[:id] == "local-2" }
	assert_equal([], remote_center_node.parents.to_a)
	assert_equal([], remote_center_node.enum_for(:each_planning_task).to_a)
	assert_equal([], local_center_node.parents.to_a)
	assert_equal([], local_center_node.enum_for(:each_planning_task).to_a)
    end

    def test_add_relation_between_existing_tasks
	peer2peer do |remote|
	    testcase = self
	    remote.singleton_class.class_eval do
		define_method(:add_tasks) { testcase.add_tasks(remote.plan, "remote") }
		define_method(:check_resulting_plan) do |plan|
		    local_peer = Distributed.peer("local")
		    testcase.check_resulting_plan(local_peer.proxy(plan)) 
		end
		define_method(:assert_cleared_relations) { testcase.assert_cleared_relations(remote.plan) }
	    end
	end

	# First, add relations between two nodes that are already existing
	r_t1, r_t2, r_t3 = remote.add_tasks.map { |t| remote_peer.proxy(t) }
	t1, t2, t3 = add_tasks(local.plan, "local")

	# Create the transaction, and do the necessary modifications
	trsc = Distributed::Transaction.new(local.plan)
	trsc.add_owner remote_peer
	trsc.self_owned
	trsc.propose(remote_peer)
	remote_peer.subscribe(r_t2)
	apply_remote_command

	trsc[r_t2].realized_by trsc[t2]
	apply_remote_command
	check_resulting_plan(trsc)
	remote.check_resulting_plan(trsc)

	# Remove the relations in the real tasks (not the proxies)
	t1.remove_child(t2)
	t2.remove_planning_task(t3)
	r_t1.remote_object(remote_peer).remove_child(r_t2.remote_object(remote_peer))
	r_t2.remote_object(remote_peer).remove_planning_task(r_t3.remote_object(remote_peer))
	apply_remote_command
	assert_cleared_relations(local.plan)
	remote.assert_cleared_relations
	
	# Commit and check the result
	trsc.commit_transaction
	apply_remote_command
    end
end


