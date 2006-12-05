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

    def test_subscribe_plan
	peer2peer do |remote|
	    mission = Task.new :id => 'mission'
	    subtask = Task.new :id => 'subtask'
	    next_mission = Task.new :id => 'next_mission'
	    mission.realized_by subtask
	    mission.on(:start, next_mission, :start)
	    remote.plan.insert(mission)
	    remote.plan.insert(next_mission)
	end
	r_mission = remote_task(:id => 'mission')
	r_subtask = remote_task(:id => 'subtask')
	r_next_mission = remote_task(:id => 'next_mission')

	# Subscribe to the remote plan
	remote_plan = remote_peer.remote_server.plan
	remote_peer.subscribe(remote_plan)
	apply_remote_command

	# Check that the remote plan has been mapped locally
	tasks = local.plan.known_tasks
	assert_equal(3, tasks.size)
	assert(p_mission = tasks.find { |t| t == remote_peer.proxy(r_mission) })
	assert(p_subtask = tasks.find { |t| t == remote_peer.proxy(r_subtask) })
	assert(p_next_mission = tasks.find { |t| t == remote_peer.proxy(r_next_mission) })

	assert(p_mission.child_object?(p_subtask, TaskStructure::Hierarchy))
	assert(p_mission.event(:start).child_object?(p_next_mission.event(:start), EventStructure::Signal))
    end

    def test_plan_updates
	peer2peer do |remote|
	    class << remote
		attr_reader :mission, :subtask, :next_mission
		def create_mission
		    @mission = Roby::Task.new :id => 'mission'
		    plan.insert(mission)
		end
		def create_subtask
		    @subtask = Roby::Task.new :id => 'subtask'
		    mission.realized_by subtask
		end
		def create_next_mission
		    @next_mission = Roby::Task.new :id => 'next_mission'
		    mission.on(:start, next_mission, :start)
		    plan.insert(next_mission)
		end
	    end
	end

	# Subscribe to the remote plan
	remote_plan = remote_peer.remote_server.plan
	remote_peer.subscribe(remote_plan)
	apply_remote_command

	remote.create_mission
	apply_remote_command
	r_mission = remote_task(:id => 'mission')
	assert_equal(1, local.plan.size)
	assert(p_mission = local.plan.known_tasks.find { |t| t == remote_peer.proxy(r_mission) })

	remote.create_subtask
	apply_remote_command
	r_subtask = remote_task(:id => 'subtask')
	assert_equal(2, local.plan.size)
	assert(p_subtask = local.plan.known_tasks.find { |t| t == remote_peer.proxy(r_subtask) })
	assert(p_mission.child_object?(p_subtask, TaskStructure::Hierarchy))

	remote.create_next_mission
	apply_remote_command
	r_next_mission = remote_task(:id => 'next_mission')
	assert_equal(3, local.plan.size)
	assert(p_next_mission = local.plan.known_tasks.find { |t| t == remote_peer.proxy(r_next_mission) })
	assert(p_mission.event(:start).child_object?(p_next_mission.event(:start), EventStructure::Signal))
    end
end
