$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'
require 'flexmock'

class TC_DistributedPlanNotifications < Test::Unit::TestCase
    include Roby::Distributed::Test

    def test_distribute_p
	assert(Roby::Task.new.distribute?)
	klass = Class.new(Roby::Task) do
	    local_object
	end
	assert(!klass.new.distribute?)
	assert(!ConnectionTask.new.distribute?)

	assert(Roby::TaskStructure::Hierarchy.distribute?)
	assert(Roby::EventStructure::Signal.distribute?)
    end

    def test_triggers
	Roby::Distributed.allow_remote_access Proc
	peer2peer do |remote|
	    def remote.new_task(kind, args)
		new_task = kind.new(args)
		yield(new_task) if block_given?
		plan.discover(new_task)
		new_task
	    end
	    def remote.insert_task(task)
		plan.insert(task)
	    end
	end

	notification = TaskMatcher.new.
	    with_model(SimpleTask).
	    with_arguments(:id => 2)

	FlexMock.use do |mock|
	    remote.new_task(SimpleTask, :id => 3)
	    remote.new_task(Roby::Task, :id => 2)
	    remote.new_task(SimpleTask, :id => 2) do |inserted|
		mock.should_receive(:notified).with(remote_peer.proxy(inserted)).once.ordered
		nil
	    end
	    remote_peer.on(notification) do |task|
		mock.notified(task)
		nil
	    end
	    process_events

	    remote.new_task(SimpleTask, :id => 3)
	    remote.new_task(Roby::Task, :id => 2)
	    r2 = remote.new_task(SimpleTask, :id => 2) do |inserted|
		mock.should_receive(:notified).with(remote_peer.proxy(inserted)).once.ordered
		nil
	    end
	    process_events

	    remote.insert_task(r2.remote_object)
	    process_events
	end
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
	remote_peer.subscribe(remote_plan.remote_object)
	process_events

	# Check that the remote plan has been mapped locally
	tasks = local.plan.known_tasks
	assert_equal(4, tasks.size)
	assert(p_mission = tasks.find { |t| t.arguments[:id] == 'mission' })
	assert(p_subtask = tasks.find { |t| t.arguments[:id] == 'subtask' })
	assert(p_next_mission = tasks.find { |t| t.arguments[:id] == 'next_mission' })

	assert(p_mission.child_object?(p_subtask, TaskStructure::Hierarchy))
	assert(p_mission.event(:start).child_object?(p_next_mission.event(:start), EventStructure::Signal))
    end

    def test_plan_updates
	peer2peer do |remote|
	    class << remote
		attr_reader :mission, :subtask, :next_mission, :free_event
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
		def create_free_event
		    @free_event = Roby::EventGenerator.new(true)
		    plan.discover(free_event)
		end
		def remove_free_event
		    plan.remove_object(free_event)
		end
		def unlink_next_mission; mission.event(:start).remove_signal(next_mission.event(:start)) end
		def remove_next_mission; plan.remove_object(next_mission) end
		def unlink_subtask; mission.remove_child(subtask) end
		def remove_subtask; plan.remove_object(subtask) end
		def discard_mission; plan.discard(mission) end
		def remove_mission; plan.remove_object(mission) end
	    end
	end

	# Subscribe to the remote plan
	remote_plan = remote_peer.remote_server.plan
	remote_peer.subscribe(remote_plan.remote_object)
	process_events
	assert(remote_peer.subscribed?(remote_plan.remote_object), remote_peer.subscriptions)

	remote.create_mission
	process_events
	r_mission = remote_task(:id => 'mission')
	# NOTE: the count is always remote_tasks + 1 since we have the ConnectionTask for our connection
	assert_equal(2, local.plan.size, local.plan.known_tasks.to_a)
	assert(p_mission = local.plan.known_tasks.find { |t| t == remote_peer.proxy(r_mission) })
	assert(remote_peer.subscribed?(r_mission.remote_object), remote_peer.subscriptions)

	remote.create_subtask
	process_events
	r_subtask = remote_task(:id => 'subtask')
	assert_equal(3, local.plan.size)
	assert(p_subtask = local.plan.known_tasks.find { |t| t == remote_peer.proxy(r_subtask) })
	assert(p_mission.child_object?(p_subtask, TaskStructure::Hierarchy))
	assert(remote_peer.subscribed?(r_subtask.remote_object), remote_peer.subscriptions)

	remote.create_next_mission
	process_events
	r_next_mission = remote_task(:id => 'next_mission')
	assert_equal(4, local.plan.size)
	assert(p_next_mission = local.plan.known_tasks.find { |t| t == remote_peer.proxy(r_next_mission) })
	assert(p_mission.event(:start).child_object?(p_next_mission.event(:start), EventStructure::Signal))
	assert(remote_peer.subscribed?(r_next_mission.remote_object), remote_peer.subscriptions)

	remote.create_free_event
	process_events
	assert_equal(1, local.plan.free_events.size)

	remote.remove_free_event
	process_events
	assert_equal(0, local.plan.free_events.size)

	remote.unlink_next_mission
	process_events
	assert_equal(4, local.plan.size)
	assert(!p_mission.event(:start).child_object?(p_next_mission.event(:start), EventStructure::Signal))

	remote.remove_next_mission
	process_events
	assert(!remote_peer.subscribed?(r_next_mission.remote_object), remote_peer.subscriptions)
	assert_equal(3, local.plan.size)
	assert(!local.plan.known_tasks.find { |t| t.arguments[:id] == 'next_mission' })

	remote.unlink_subtask
	process_events
	assert_equal(3, local.plan.size)
	assert(!p_mission.child_object?(p_subtask, TaskStructure::Hierarchy))

	remote.remove_subtask
	process_events
	assert(!remote_peer.subscribed?(r_subtask.remote_object), remote_peer.subscriptions)
	assert_equal(2, local.plan.size)
	assert(!local.plan.known_tasks.find { |t| t.arguments[:id] == 'subtask' })

	assert(local.plan.missions.find { |t| t.arguments[:id] == 'mission' })
	remote.discard_mission
	process_events
	assert(local.plan.missions.empty?)
	assert(local.plan.known_tasks.find { |t| t.arguments[:id] == 'mission' })

	remote.remove_mission
	process_events
	assert_equal(1, local.plan.size)
	assert(!local.plan.known_tasks.find { |t| t.arguments[:id] == 'mission' })
    end

    def test_unsubscribe_plan
	peer2peer do |remote|
	    mission = Task.new :id => 'mission'
	    subtask = Task.new :id => 'subtask'
	    mission.realized_by subtask
	    remote.plan.insert(mission)

	    remote.class.class_eval do
		define_method(:remove_subtask) do 
		    plan.remove_object(subtask)
		end
	    end
	end

	remote_peer.subscribe(remote_peer.remote_server.plan)
	process_events
	remote_peer.unsubscribe(remote_peer.remote_server.plan)
	process_events
	assert_equal(3, local.plan.size)
	remote.remove_subtask
	process_events
	assert_equal(2, local.plan.size)
    end
end
