$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'distributed/common.rb'
require 'roby/distributed/transaction'
require 'mockups/tasks'

# This testcase tests behaviour of plans with both remote and local tasks
# interacting with each other
class TC_DistributedMixedPlan < Test::Unit::TestCase
    include DistributedTestCommon

    def test_direct_modifications
	peer2peer do |remote|
	    remote.plan.insert(SimpleTask.new(:id => 1))
	end
	r_task = remote_task(:id => 1)
	p_task = remote_peer.proxy(r_task)

	task = Task.new(:id => 'local')
	assert(p_task.read_only?)
	assert(!task.read_only?)
	assert(p_task.event(:start).read_only?)
	assert(!task.event(:start).read_only?)
	assert_raises(NotOwner) { p_task.realized_by task }
	assert_raises(NotOwner) { task.event(:start).on p_task.event(:start) }
	assert_nothing_raised { p_task.event(:start).on task.event(:start) }

	assert_equal(local.plan, task.plan)

	trsc = Distributed::Transaction.new(local.plan)
	trsc.self_owned
	trsc.add_owner remote_peer
	trsc.propose(remote_peer)
	apply_remote_command
	remote_peer.subscribe(p_task)
	apply_remote_command

	trsc[p_task].realized_by trsc[task]
	trsc.commit_transaction
	apply_remote_command

	assert_nothing_raised { p_task.remove_child task }
    end

    def test_free_events
    end
end


