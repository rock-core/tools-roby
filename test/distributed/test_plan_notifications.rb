require 'roby/test/distributed'
require 'roby/tasks/simple'

class TC_DistributedPlanNotifications < Minitest::Test
    def test_triggers
	peer2peer do |remote|
	    def remote.new_task(kind, args)
		engine.execute do
		    new_task = kind.proxy(local_peer).new(args)
		    yield(new_task.remote_id) if block_given?
		    plan.add_mission(new_task)
		end
		nil
	    end
	end

	notification = TaskMatcher.new.
	    with_model(Tasks::Simple).
	    with_arguments(:id => 2)

	FlexMock.use do |mock|
	    remote_peer.on(notification) do |task|
		assert(plan.useful_task?(task))
		assert(task.plan)
		mock.notified(task.sibling_on(remote_peer))
		nil
	    end

	    simple_task = Distributed.format(Tasks::Simple)
	    roby_task   = Distributed.format(Roby::Task)

	    remote.new_task(simple_task, :id => 3)
	    remote.new_task(roby_task, :id => 2)
	    remote.new_task(simple_task, :id => 2) do |inserted_id|
		mock.should_receive(:notified).with(inserted_id).once.ordered
		nil
	    end

	    remote.new_task(simple_task, :id => 3)
	    remote.new_task(roby_task, :id => 2)
	    remote.new_task(simple_task, :id => 2) do |inserted_id|
		mock.should_receive(:notified).with(inserted_id).once.ordered
		nil
	    end

	    remote_peer.synchro_point
	end
    end

    def test_trigger_subscribe
	peer2peer do |remote|
	    def remote.new_task
		plan.add_mission(Tasks::Simple.new(:id => 1))
		nil
	    end
	end

	notification = TaskMatcher.new.
	    with_model(Tasks::Simple).
	    with_arguments(:id => 1)

	task = nil
	remote_peer.on(notification) do |t|
	    remote_peer.subscribe(t)
	    task = t
	end
	remote.new_task
	while !task
	    remote_peer.synchro_point
	end

	assert(task)
	assert_equal([task], plan.find_tasks.with_arguments(:id => 1).to_a)
    end

    def test_subscribe_plan
	peer2peer do |remote|
	    plan.add_mission(mission = Tasks::Simple.new(:id => 'mission'))
	    subtask = Tasks::Simple.new :id => 'subtask'
	    plan.add_mission(next_mission = Tasks::Simple.new(:id => 'next_mission'))
	    mission.depends_on subtask
	    mission.signals(:start, next_mission, :start)
	end

	# Subscribe to the remote plan
	remote_peer.subscribe_plan
	assert(remote_peer.subscribed_plan?)

	# Check that the remote plan has been mapped locally
	process_events
	tasks = plan.known_tasks
	assert_equal(4, tasks.size)
	assert(p_mission = tasks.find { |t| t.arguments[:id] == 'mission' })
	assert(p_subtask = tasks.find { |t| t.arguments[:id] == 'subtask' })
	assert(p_next_mission = tasks.find { |t| t.arguments[:id] == 'next_mission' })

	assert(p_mission.child_object?(p_subtask, TaskStructure::Dependency))
	assert(p_mission.event(:start).child_object?(p_next_mission.event(:start), EventStructure::Signal))
    end

    def test_plan_updates
	peer2peer do |remote|
	    class << remote
		attr_reader :mission, :subtask, :next_mission, :free_event
		def create_mission
		    @mission = Roby::Task.new :id => 'mission'
		    plan.add_mission(mission)
		end
		def create_subtask
		    plan.add_permanent(@subtask = Roby::Task.new(:id => 'subtask'))
		    mission.depends_on subtask
		end
		def create_next_mission
		    @next_mission = Roby::Task.new :id => 'next_mission'
		    mission.signals(:start, next_mission, :start)
		    plan.add_mission(next_mission)
		end
		def create_free_event
		    @free_event = Roby::EventGenerator.new(true)
		    # Link the event to a task to protect it from GC
		    @next_mission.signals(:start, @free_event, :start)
		    plan.add(free_event)
		end
		def remove_free_event
		    plan.remove_object(free_event)
		end
		def unlink_next_mission; mission.event(:start).remove_signal(next_mission.event(:start)) end
		def remove_next_mission; plan.remove_object(next_mission) end
		def unlink_subtask; mission.remove_child(subtask) end
		def remove_subtask; plan.remove_object(subtask) end
		def discard_mission 
		    plan.add_permanent(mission)
		    plan.unmark_mission(mission) 
		end
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
	assert(p_mission.child_object?(p_subtask, TaskStructure::Dependency))

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
	assert(p_subtask.subscribed?)
	process_events
	assert_equal(3, plan.size, plan.known_tasks)
	assert(!p_mission.child_object?(p_subtask, TaskStructure::Dependency))

	remote.remove_subtask
	process_events
	assert_equal(2, plan.size)
	assert(!p_subtask.plan)

	remote.discard_mission
	process_events
	assert(!p_mission.mission?)

	remote.remove_mission
	process_events
	assert_equal(1, plan.size)
	assert(!p_mission.plan)
    end

    def test_unsubscribe_plan
	peer2peer do |remote|
	    remote.plan.add_mission(Tasks::Simple.new(:id => 'remote-1'))
	    remote.plan.add_mission(Tasks::Simple.new(:id => 'remote-2'))

	    def remote.new_task
		plan.add_mission(Tasks::Simple.new(:id => 'remote-3'))
	    end
	end

	remote_peer.subscribe_plan
	assert_equal(3, plan.size)

	# Subscribe to the remote-1 task and unsubscribe to the plan
	r1 = *plan.find_tasks.with_arguments(:id => 'remote-1').to_a
	remote_peer.subscribe(r1)

	remote_peer.unsubscribe_plan
	assert(!remote_peer.subscribed_plan?)

	# Start plan GC, the subscribed task should remain
	process_events
	assert_equal(2, plan.size, plan.known_tasks)

	# Add a new task in the remote plan, check we do not get the updates
	# anymore
	remote.new_task
	process_events
	assert_equal(2, plan.size)
    end
end
