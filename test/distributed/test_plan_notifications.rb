$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'
require 'flexmock'

class TC_DistributedPlanNotifications < Test::Unit::TestCase
    include Roby::Distributed::Test

    def test_triggers
	Roby::Distributed.allow_remote_access Proc
	peer2peer do |remote|
	    def remote.new_task(kind, args)
		new_task = kind.new(args)
		yield(new_task) if block_given?
		plan.insert(new_task)
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
	    remote_peer.on(notification) do |task|
		mock.notified(task.sibling_on(remote_peer))
		nil
	    end

	    remote.new_task(SimpleTask, :id => 3)
	    remote.new_task(Roby::Task, :id => 2)
	    remote.new_task(SimpleTask, :id => 2) do |inserted|
		mock.should_receive(:notified).with(inserted.remote_object).once.ordered
		nil
	    end
	    process_events

	    remote.new_task(SimpleTask, :id => 3)
	    remote.new_task(Roby::Task, :id => 2)
	    remote.new_task(SimpleTask, :id => 2) do |inserted|
		mock.should_receive(:notified).with(inserted.remote_object).once.ordered
		nil
	    end
	    process_events
	end
    end

    def test_subscribe_plan
	peer2peer(true) do |remote|
	    plan.insert(mission = Task.new(:id => 'mission'))
	    subtask = Task.new :id => 'subtask'
	    plan.insert(next_mission = Task.new(:id => 'next_mission'))
	    mission.realized_by subtask
	    mission.on(:start, next_mission, :start)
	end

	# Subscribe to the remote plan
	remote_peer.subscribe_plan

	# Check that the remote plan has been mapped locally
	tasks = plan.known_tasks
	assert_equal(4, tasks.size)
	assert(p_mission = tasks.find { |t| t.arguments[:id] == 'mission' })
	assert(p_subtask = tasks.find { |t| t.arguments[:id] == 'subtask' })
	assert(p_next_mission = tasks.find { |t| t.arguments[:id] == 'next_mission' })

	assert(p_mission.child_object?(p_subtask, TaskStructure::Hierarchy))
	assert(p_mission.event(:start).child_object?(p_next_mission.event(:start), EventStructure::Signal))
    end

    def test_plan_updates
	peer2peer(true) do |remote|
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
		    # Link the event to a task to protect it from GC
		    @next_mission.on(:start, @free_event)
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
	remote_peer.subscribe_plan

	remote.create_mission
	process_events
	p_mission = remote_task(:id => 'mission')
	# NOTE: the count is always remote_tasks + 1 since we have the ConnectionTask for our connection
	assert_equal(2, plan.size, plan.known_tasks.to_a)
	assert(p_mission.mission?)
	process_events
	assert(p_mission.plan)

	remote.create_subtask
	process_events
	p_subtask = remote_task(:id => 'subtask')
	assert_equal(3, plan.size)
	assert(p_mission.child_object?(p_subtask, TaskStructure::Hierarchy))

	remote.create_next_mission
	process_events
	p_next_mission = remote_task(:id => 'next_mission')
	assert_equal(4, plan.size)
	assert(p_mission.event(:start).child_object?(p_next_mission.event(:start), EventStructure::Signal))

	remote.create_free_event
	process_events
	assert_equal(1, plan.free_events.size)
	process_events
	assert_equal(1, plan.free_events.size)

	remote.remove_free_event
	process_events
	assert_equal(0, plan.free_events.size)

	remote.unlink_next_mission
	process_events
	assert_equal(4, plan.size)
	assert(!p_mission.event(:start).child_object?(p_next_mission.event(:start), EventStructure::Signal))

	remote.remove_next_mission
	process_events
	assert_equal(3, plan.size)
	assert(!p_next_mission.plan)

	remote.unlink_subtask
	process_events
	assert_equal(3, plan.size)
	assert(!p_mission.child_object?(p_subtask, TaskStructure::Hierarchy))

	remote.remove_subtask
	process_events
	assert_equal(2, plan.size)
	assert(!p_subtask.plan)

	remote.discard_mission
	process_events
	assert(!p_mission.mission?)
	assert(p_mission.plan)

	remote.remove_mission
	process_events
	assert_equal(1, plan.size)
	assert(!p_mission.plan)
    end

    def test_unsubscribe_plan
	peer2peer(true) do |remote|
	    remote.plan.insert(Task.new(:id => 'remote-1'))
	    remote.plan.insert(Task.new(:id => 'remote-2'))

	    def remote.new_task
		plan.insert(Task.new(:id => 'remote-3'))
	    end
	end

	remote_peer.subscribe_plan
	assert_equal(3, plan.size)

	# Subscribe to the remote-1 task and unsubscribe to the plan
	r1 = *plan.find_tasks.with_arguments(:id => 'remote-1').to_a
	remote_peer.subscribe(r1)

	remote_peer.unsubscribe_plan
	process_events

	# The subscribed task should remain
	assert_equal(2, plan.size)

	# Add a new task in the remote plan, check we do not get the updates
	# anymore
	remote.new_task
	process_events
	assert_equal(2, plan.size)
    end
end
