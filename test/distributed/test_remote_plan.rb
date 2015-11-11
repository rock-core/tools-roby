require 'roby/test/distributed'
require 'roby/tasks/simple'

# This testcase tests local views of remote plans
class TC_DistributedRemotePlan < Minitest::Test
    def test_distributed_update
	objects = (1..10).map { |i| Tasks::Simple.new(:id => i) }
	obj = Object.new

	Distributed.update(obj) do
	    assert(Distributed.updating?(obj))
	end
	assert(!Distributed.updating?(obj))

	Distributed.update_all(objects) do
	    objects.each { |o| assert(Distributed.updating?(o)) }
	    assert(Distributed.updating_all?(objects))
	    assert(!Distributed.updating?(obj))
	    assert(!Distributed.updating_all?(objects.dup << obj))
	end
	objects.each { |o| assert(!Distributed.updating?(o)) }
	assert(!Distributed.updating_all?(objects))

	# Recursive behaviour
	Distributed.update(obj) do
	    Distributed.update(obj) do
		assert(Distributed.updating?(obj))
	    end
	    assert(Distributed.updating?(obj))

	    Distributed.update_all(objects) do
		objects.each { |o| assert(Distributed.updating?(o)) }
		assert(Distributed.updating_all?(objects))
		assert(Distributed.updating?(obj))
		assert(Distributed.updating_all?(objects.dup << obj))
	    end
	    objects.each { |o| assert(!Distributed.updating?(o), o) }
	    assert(!Distributed.updating_all?(objects))
	    assert(!Distributed.updating_all?(objects.dup << obj))
	    assert(Distributed.updating?(obj))
	end
	assert(!Distributed.updating?(obj))

	# Recursive behaviour
	Distributed.update_all(objects) do
	    Distributed.update(obj) do
		assert(Distributed.updating?(obj))
		assert(Distributed.updating_all?(objects.dup << obj))
	    end
	    assert(!Distributed.updating?(obj))
	    assert(Distributed.updating_all?(objects))

	    Distributed.update_all(objects[1..4]) do
		assert(Distributed.updating_all?(objects))
		assert(!Distributed.updating?(obj))
	    end
	    assert(Distributed.updating_all?(objects))
	    assert(!Distributed.updating_all?(objects.dup << obj))
	    assert(!Distributed.updating?(obj))
	end
	assert(!Distributed.updating?(obj))
	assert(!Distributed.updating_all?(objects))
    end

    def test_remote_proxy_update
	peer2peer do |remote|
	    remote.plan.add_mission(Tasks::Simple.new(:id => 'simple_task'))
	    remote.plan.add_permanent(Tasks::Simple.new(:id => 'task'))
	    remote.plan.add_permanent(Tasks::Simple.new(:id => 'other_task'))
	end

	r_simple_task = remote_task(:id => 'simple_task', :permanent => true)
	r_task        = remote_task(:id => 'task', :permanent => true)
	r_other_task  = remote_task(:id => 'other_task', :permanent => true)

	task = Tasks::Simple.new
	assert(!r_simple_task.read_write?, r_simple_task.plan)
	Distributed.update(r_simple_task) do
	    assert(r_simple_task.read_write?)
            r_simple_task.depends_on task
            r_simple_task.remove_child task
            task.depends_on r_simple_task
            task.remove_child r_simple_task
	end
	assert(!r_simple_task.read_write?)

	assert_raises(OwnershipError) { r_simple_task.depends_on task }
	assert_raises(OwnershipError) { task.depends_on r_simple_task }
	Distributed.update(r_simple_task) { r_simple_task.depends_on task }
	r_simple_task.remove_child task
	Distributed.update(r_simple_task) { task.depends_on r_simple_task }
	task.remove_child r_simple_task

	assert_raises(OwnershipError) { r_simple_task.depends_on r_other_task }
	assert_raises(OwnershipError) { r_other_task.depends_on r_simple_task }
	Distributed.update_all([r_simple_task, r_other_task]) { r_simple_task.depends_on r_other_task }
	assert_raises(OwnershipError) { r_simple_task.remove_child r_other_task }
	Distributed.update_all([r_simple_task, r_other_task]) do
	    r_simple_task.remove_child r_other_task
	    r_other_task.depends_on r_simple_task
	end
	assert_raises(OwnershipError) { r_other_task.remove_child r_simple_task }

	# Force a synchro point, or we will have a conflict between the remote
	# GC process and the pending messages
	#
	# ... did I already told that distributed transactions were here for
	# something ?
	remote_peer.synchro_point
    end

    # Test that the remote plan structure is properly mapped to the local
    # plan database
    def test_discover_neighborhood
	peer2peer do |remote|
	    mission, subtask, next_mission =
		Tasks::Simple.new(:id => 'mission'), 
		Tasks::Simple.new(:id => 'subtask'),
		Tasks::Simple.new(:id => 'next_mission')
	    mission.depends_on subtask
	    mission.signals(:stop, next_mission, :start)

	    remote.plan.add_mission(mission)
	    remote.plan.add_mission(next_mission)
	end

	r_mission	= remote_task(:id => 'mission', :permanent => true)
	r_subtask	= remote_task(:id => 'subtask', :permanent => true)
	r_next_mission  = remote_task(:id => 'next_mission', :permanent => true)

	# We don't know about the remote relations
	assert_equal([], r_mission.children.to_a)
	assert_equal([], r_mission.event(:stop).child_objects(EventStructure::Signal).to_a)

	# add remote relations
	remote_peer.discover_neighborhood(r_mission, 1) do |r_mission|
	    proxies = r_mission.children.to_a
	    assert_equal(1, proxies.to_a.size)
	    assert_equal(r_subtask, proxies.first)
	    proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(r_next_mission.event(:start), proxies.first)
	end

	plan.unmark_permanent(r_mission)
	plan.unmark_permanent(r_subtask)
	plan.unmark_permanent(r_next_mission)
	engine.wait_one_cycle
	assert_equal([remote_peer.task], plan.permanent_tasks.to_a)
    end

    def test_subscribing_old_objects
	peer2peer do |remote|
	    plan.add_mission(@task = Tasks::Simple.new(:id => 1))
	end

	r_task, r_task_id = nil
	r_task = remote_task(:id => 1) do |t|
	    assert(r_task_id = t.remote_siblings[remote_peer])
	    t
	end

	process_events
	assert(!r_task.plan)
	assert_raises(Roby::RemotePeerMismatch) { remote_peer.subscribe(r_task) }
    end

    def test_subscription
	peer2peer do |remote|
	    root, mission, subtask, next_mission =
		Tasks::Simple.new(:id => 'root'), 
		Tasks::Simple.new(:id => 'mission'), 
		Tasks::Simple.new(:id => 'subtask'),
		Tasks::Simple.new(:id => 'next_mission')
	    root.depends_on mission
	    mission.depends_on subtask
	    mission.signals(:stop, next_mission, :start)

	    remote.plan.add_permanent(subtask)
	    remote.plan.add_mission(root)
	    remote.plan.add_mission(mission)
	    remote.plan.add_mission(next_mission)

	    remote.singleton_class.class_eval do
		include Minitest::Assertions
		def check_local_updated(m_task)
		    task    = local_peer.local_object(m_task)
		    sibling = nil
		    sibling = task.sibling_on(local_peer)
		    assert(!task.subscribed?)
		    assert(task.updated?)
		    assert(task.update_on?(local_peer))
		    assert(task.updated_by?(local_peer))
		    assert_equal([local_peer], Distributed.enum_for(:each_updated_peer, task).to_a)
		    assert_equal([local_peer], task.updated_peers)
		    assert(task.remotely_useful?)
		end

		define_method(:remove_mission_subtask) do
		    mission.remove_child subtask
		end
		define_method(:add_mission_subtask) do
		    mission.depends_on subtask
		end
	    end
	end

	r_root = subscribe_task(:id => 'root')
	# Check that the task index has been updated
	assert(plan.task_index.by_owner[remote_peer].include?(r_root))
	
	# No need to explicitely synchronize here. #subscribe is supposed to return only
	# when the subscription is completely done (i.e. the remote peer knows we have 
	# a sibling)
	remote.check_local_updated(Distributed.format(r_root))
	assert(r_root.subscribed?, remote_peer.subscriptions)
	assert(r_root.updated_by?(remote_peer))
	assert(r_root.update_on?(remote_peer))
	assert_equal([remote_peer], r_root.updated_peers)
	assert(!r_root.remotely_useful?)
	assert_equal([remote_peer], Distributed.enum_for(:each_updated_peer, r_root).to_a)

	assert(r_root.mission?)
	r_mission = remote_task(:id => 'mission')
	assert_equal([r_mission], r_root.children.to_a)
	assert_equal([], r_mission.children.to_a)
	assert_equal([], r_mission.event(:stop).child_objects(EventStructure::Signal).to_a)

	assert(plan.useful_task?(r_mission))
	r_next_mission = remote_task(:id => 'next_mission')
	r_subtask = remote_task(:id => 'subtask')
	Roby.synchronize do
	    assert(!r_next_mission.plan || !plan.useful_task?(r_next_mission))
	    assert(!r_subtask.plan || !plan.useful_task?(r_subtask))
	end
	engine.wait_one_cycle
	
	# Check that the task index has been updated
	assert(!plan.task_index.by_owner[remote_peer].include?(r_subtask))

	# Check that subscribing again is handled nicely
	assert_same(r_root, remote_peer.subscribe(r_root))
	assert_same(r_mission, remote_peer.subscribe(r_mission))
	r_subtask = remote_task(:id => 'subtask')
	assert(!plan.unneeded_tasks.include?(r_subtask))
	r_next_mission = remote_task(:id => 'next_mission')
	Roby.synchronize do
	    assert(!r_next_mission.plan || plan.unneeded_tasks.include?(r_next_mission))
	end

	assert_equal([r_subtask], r_mission.children.to_a)

	## Check plan GC after we have unsubscribed from mission
	remote_peer.unsubscribe(r_mission)
	Roby.synchronize do
	    assert(r_mission.plan)
	    assert(!plan.unneeded_tasks.include?(r_mission))
	    assert(!remote_peer.subscribed?(r_mission))
	    assert(plan.unneeded_tasks.include?(r_subtask))
	end
	engine.wait_one_cycle

	# Check that subtask and next_mission are removed from the plan
	assert(!r_subtask.plan)
	assert_raises(RemotePeerMismatch) { r_subtask.sibling_on(remote_peer) }
	subtask_proxy = remote_peer.proxies.find do |_, obj| 
	    obj == r_subtask || 
		(obj.root_object == r_subtask if obj.respond_to?(:root_object))
	end
	assert(!subtask_proxy)
	assert_raises(RemotePeerMismatch) { r_next_mission.sibling_on(remote_peer) }
	next_mission_proxy = remote_peer.proxies.find do |_, obj| 
	    obj == r_next_mission || 
		(obj.root_object == r_next_mission if obj.respond_to?(:root_object))
	end
	assert(!next_mission_proxy)
	# Check that mission is still included, and is still linked to root
	assert(r_mission.plan)
	assert(r_root.child_object?(r_mission, TaskStructure::Dependency))

	## Check that #subscribe takes the plan modification into account
	remote.remove_mission_subtask
	assert_same(r_mission, remote_peer.subscribe(r_mission))
	proxies = r_mission.children.to_a
	assert(proxies.empty?, proxies)
	assert(!plan.unneeded_tasks.include?(r_mission))
	assert(!plan.unneeded_tasks.include?(r_mission.event(:stop)))

	## Re-add the child relation and test #unsubscribe
	remote_peer.unsubscribe(r_mission)
	process_events
	remote.add_mission_subtask
	process_events
	assert(r_mission.plan)
	assert(r_mission.leaf?(TaskStructure::Dependency))

	r_mission = remote_peer.subscribe(r_mission)
	r_subtask = remote_task(:id => 'subtask')
	r_next_mission = remote_task(:id => 'next_mission')
	engine.wait_one_cycle

	proxies = r_mission.children.to_a
	assert(! proxies.empty?)
    end

    def test_remove_not_needed
	peer2peer do |remote|
	    left, right, middle =
		Tasks::Simple.new(:id => 'left'), 
		Tasks::Simple.new(:id => 'right'), 
		Tasks::Simple.new(:id => 'middle')
	    remote.plan.add_mission(left)
	    remote.plan.add_mission(right)

	    left.depends_on middle
	    right.depends_on middle

	    remote.singleton_class.class_eval do
		include Minitest::Assertions
		define_method(:remove_last_link) do
		    assert(left.update_on?(local_peer))
		    assert(middle.update_on?(local_peer))
		    left.remove_child(middle)
		    nil
		end
	    end
	end

	left   = subscribe_task(:id => 'left')
	right  = subscribe_task(:id => 'right')
	middle = remote_task(:id => 'middle')
	assert(!middle.subscribed?)
	assert(!plan.unneeded_tasks.include?(left))
	assert(!plan.unneeded_tasks.include?(right))
	assert(!plan.unneeded_tasks.include?(middle))

	Roby.synchronize do
	    remote_peer.unsubscribe(right)
	    assert(!right.remotely_useful?)
	    assert(!right.subscribed?)
	    assert(plan.unneeded_tasks.include?(right))
	    assert(!plan.unneeded_tasks.include?(middle))
	end
	process_events
	assert(!right.plan)

	assert(middle.plan)
	assert_equal(1, middle.parent_objects(TaskStructure::Dependency).to_a.size)

	remote.remove_last_link
	process_events
	assert(!middle.plan)
    end

    def test_data_update
	peer2peer do |remote|
	    task = Tasks::Simple.new(:id => 'task')
	    task.data = [4, 2]
	    remote.plan.add_mission(task)

	    remote.singleton_class.class_eval do 
		define_method(:change_data) { task.data = 42 }
	    end
	end
	task = subscribe_task(:id => 'task')
	assert_equal([4, 2], task.data)

	remote.change_data
	process_events
	assert_equal(42, task.data)
    end

    def test_mission_notifications
	peer2peer do |remote|
	    plan.add_mission(mission = Tasks::Simple.new(:id => 'mission'))

	    remote.class.class_eval do
		define_method(:discard_mission) do
		    Roby.synchronize do
			remote.plan.unmark_mission(mission)
			remote.plan.add_permanent(mission)
		    end
		end
		define_method(:insert_mission) do
		    Roby.synchronize do
			remote.plan.unmark_permanent(mission)
			remote.plan.add_mission(mission)
		    end
		end
	    end
	end
	r_mission = subscribe_task(:id => 'mission')
	assert(r_mission.mission?)
	assert(!plan.mission?(r_mission))

	remote.discard_mission
	process_events
	assert(!r_mission.mission?)
	assert(!plan.mission?(r_mission))

	remote.insert_mission
	process_events
	assert(r_mission.mission?)
	assert(!plan.mission?(r_mission))
    end

    def test_relation_updates
	peer2peer do |remote|
	    mission, subtask, next_mission =
		Tasks::Simple.new(:id => 'mission'), 
		Tasks::Simple.new(:id => 'subtask'),
		Tasks::Simple.new(:id => 'next_mission')

	    remote.plan.add_mission(mission)
	    remote.plan.add_mission(next_mission)
	    remote.plan.add_permanent(subtask)

	    remote.singleton_class.class_eval do
		define_method(:add_mission_subtask) do
		    mission.depends_on subtask
		end
		define_method(:remove_mission_subtask) do
		    mission.remove_child subtask
		end
		define_method(:add_mission_stop_next_start) do
		    mission.signals(:stop, next_mission, :start)
		end
		define_method(:remove_mission_stop_next_start) do
		    mission.event(:stop).remove_signal(next_mission.event(:start))
		end
	    end
	end

	r_mission	= subscribe_task(:id => 'mission')
	r_subtask 	= subscribe_task(:id => 'subtask')
	r_next_mission  = subscribe_task(:id => 'next_mission')

	remote.add_mission_subtask
	process_events
	assert_equal([r_subtask], r_mission.children.to_a)

	remote.remove_mission_subtask
	process_events
	assert(r_mission.leaf?(TaskStructure::Dependency))

	remote.add_mission_stop_next_start
	process_events
	assert_equal([r_next_mission.event(:start)], r_mission.event(:stop).child_objects(EventStructure::Signal).to_a)

	remote.remove_mission_stop_next_start
	process_events
	assert(r_mission.event(:stop).leaf?(EventStructure::Signal))
    end

    # Check that remote events that are unknown locally are properly ignored
    def test_ignored_events
	peer2peer do |remote|
	    model = Tasks::Simple.new_submodel do
		event :unknown, :command => true
	    end
	    remote.plan.add_mission(t1 = Tasks::Simple.new(:id => 1))
	    remote.plan.add_mission(t2 = Tasks::Simple.new(:id => 2))
	    remote.plan.add_mission(u = model.new(:id => 0))

	    t1.signals(:start, u, :unknown)
            u.forward_to(:unknown, t2, :start)

	    remote.singleton_class.class_eval do
		define_method(:remove_relations) do
		    t1.event(:start).remove_signal u.event(:unknown)
		    u.event(:unknown).remove_forwarding t2.event(:start)
		end
	    end
	end

	u = subscribe_task(:id => 0)
	t1 = remote_task(:id => 1)
	t2 = remote_task(:id => 2)

	assert(remote_peer.connected?)

	remote.remove_relations
	process_events
	assert(remote_peer.connected?)
    end
end

