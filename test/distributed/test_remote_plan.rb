$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'

# This testcase tests local views of remote plans
class TC_DistributedRemotePlan < Test::Unit::TestCase
    include Roby::Distributed::Test

    def test_distributed_update
	objects = (1..10).map { |i| SimpleTask.new(:id => i) }
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
	    remote.plan.insert(SimpleTask.new(:id => 'simple_task'))
	    remote.plan.permanent(SimpleTask.new(:id => 'task'))
	    remote.plan.permanent(SimpleTask.new(:id => 'other_task'))
	end

	proxy_model = Distributed.RemoteProxyModel(SimpleTask)
	assert(proxy_model.ancestors.include?(TaskProxy))

	# Get the MarshalledTask objects for remote tasks
	r_simple_task = remote_task(:id => 'simple_task')
	r_task        = remote_task(:id => 'task')
	r_other_task  = remote_task(:id => 'other_task')

	task = SimpleTask.new
	assert(!r_simple_task.read_write?)
	Distributed.update(r_simple_task) do
	    assert(r_simple_task.read_write?)
	    assert_nothing_raised do
		r_simple_task.realized_by task
		r_simple_task.remove_child task
		task.realized_by r_simple_task
		task.remove_child r_simple_task
	    end
	end
	assert(!r_simple_task.read_write?)

	assert_raises(NotOwner) { r_simple_task.realized_by task }
	assert_raises(NotOwner) { task.realized_by r_simple_task }
	Distributed.update(r_simple_task) { r_simple_task.realized_by task }
	assert_nothing_raised { r_simple_task.remove_child task }
	Distributed.update(r_simple_task) { task.realized_by r_simple_task }
	assert_nothing_raised { task.remove_child r_simple_task }

	assert_raises(NotOwner) { r_simple_task.realized_by r_other_task }
	assert_raises(NotOwner) { r_other_task.realized_by r_simple_task }
	Distributed.update_all([r_simple_task, r_other_task]) { r_simple_task.realized_by r_other_task }
	assert_raises(NotOwner) { r_simple_task.remove_child r_other_task }
	Distributed.update_all([r_simple_task, r_other_task]) do
	    r_simple_task.remove_child r_other_task
	    r_other_task.realized_by r_simple_task
	end
	assert_raises(NotOwner) { r_other_task.remove_child r_simple_task }
    end

    def test_task_proxy
	peer2peer do |remote|
	    remote.plan.insert(SimpleTask.new(:id => 'simple_task'))
	    remote.plan.permanent(Task.new(:id => 'task'))
	end

	proxy_model = Distributed.RemoteProxyModel(SimpleTask)
	assert(proxy_model.ancestors.include?(TaskProxy))

	r_simple_task = remote_task(:id => 'simple_task')
	r_task        = remote_task(:id => 'task')

	assert(r_simple_task.root_object?)
	assert(!r_simple_task.event(:start).root_object?)

	proxy = nil
	assert_nothing_raised { proxy = proxy_model.new(remote_peer, r_simple_task.marshalled_object) }
	assert_raises(TypeError) { proxy_model.new(remote_peer, r_task.marshalled_object) }

	assert(proxy = remote_peer.proxy(r_task))
	assert_equal(proxy.sibling_on(remote_peer), r_task.sibling_on(remote_peer))
	assert_equal(local.plan, proxy.plan)
	assert(remote_peer.owns?(proxy))
    end

    def test_event_proxy
	peer2peer do |remote|
	    remote.plan.insert(t = Task.new)
	    t.on(:start, (ev = EventGenerator.new(true)))
	    t.event(:start).forward(ev = EventGenerator.new(false))
	    t.on(:start, (ev = EventGenerator.new { }))
	    remote.class.class_eval do
		include Test::Unit::Assertions
		define_method(:event_has_happened?) { ev.happened? }
		define_method(:event_proxy) { remote.plan.free_events }
		define_method(:assert_event_count) { assert_equal(3, remote.plan.free_events.size) }
	    end
	end
	
	remote.assert_event_count
	marshalled = remote.event_proxy
	marshalled.each { |ev| assert_kind_of(Distributed::MarshalledEventGenerator, ev) }

	all_events = marshalled.map { |ev| remote_peer.proxy(ev) }
	all_events.each { |ev| assert_kind_of(Distributed::EventGeneratorProxy, ev) }
	
	assert_equal(1, all_events.find_all { |ev| !ev.controlable? }.size)
	assert_equal(2, all_events.find_all { |ev| ev.controlable? }.size)
    end

    # Test that the remote plan structure is properly mapped to the local
    # plan database
    def test_discover_neighborhood
	peer2peer do |remote|
	    mission, subtask, next_mission =
		SimpleTask.new(:id => 'mission'), 
		SimpleTask.new(:id => 'subtask'),
		SimpleTask.new(:id => 'next_mission')
	    mission.realized_by subtask
	    mission.on(:stop, next_mission, :start)

	    remote.plan.insert(mission)
	    remote.plan.insert(next_mission)
	end

	r_mission	= remote_task(:id => 'mission')
	r_subtask	= remote_task(:id => 'subtask')
	r_next_mission  = remote_task(:id => 'next_mission')

	# We don't know about the remote relations
	assert_equal([], r_mission.children.to_a)
	assert_equal([], r_mission.event(:stop).child_objects(EventStructure::Signal).to_a)

	# Discover remote relations
	remote_peer.discover_neighborhood(r_mission, 1) do |r_mission|
	    process_events

	    proxies = r_mission.children.to_a
	    assert_equal(1, proxies.size)
	    assert_equal(r_subtask, proxies.first)
	    proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(r_next_mission.event(:start), proxies.first)
	end

	process_events
	assert_equal([remote_peer.task], plan.keepalive.to_a)
    end

    def test_siblings
	peer2peer do |remote|
	    plan.insert(Roby::Task.new(:id => 'remote'))
	end

	plan.insert(remote_task = remote_task(:id => 'remote'))
	assert(remote_task.has_sibling_on?(remote_peer))
	remote_object, _ = remote_peer.proxies.find { |_, task| task == remote_task }
	assert(remote_object)
	assert_equal(remote_object, remote_task.sibling_on(remote_peer))

	assert_equal(remote_task, remote_task(:id => 'remote'))
	process_events
	assert_equal(remote_task, remote_task(:id => 'remote'))
    end

    def test_subscription
	peer2peer(true) do |remote|
	    root, mission, subtask, next_mission =
		SimpleTask.new(:id => 'root'), 
		SimpleTask.new(:id => 'mission'), 
		SimpleTask.new(:id => 'subtask'),
		SimpleTask.new(:id => 'next_mission')
	    root.realized_by mission
	    mission.realized_by subtask
	    mission.on(:stop, next_mission, :start)

	    remote.plan.permanent(subtask)
	    remote.plan.insert(root)
	    remote.plan.insert(mission)
	    remote.plan.insert(next_mission)

	    remote.singleton_class.class_eval do
		include Test::Unit::Assertions
		def check_local_updated(m_task)
		    task    = local_peer.local_object(m_task)
		    sibling = nil
		    assert_nothing_raised { sibling = task.sibling_on(local_peer) }
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
		    mission.realized_by subtask
		end
	    end
	end

	## Check that #subscribe updates the relations between subscribed objects
	r_root = remote_task(:id => 'root')
	r_root = remote_peer.subscribe(r_root)
	assert(r_root.subscribed?, remote_peer.subscriptions)
	assert(r_root.updated_by?(remote_peer))
	assert(r_root.update_on?(remote_peer))
	assert_equal([remote_peer], r_root.updated_peers)
	assert(!r_root.remotely_useful?)
	assert_equal([remote_peer], Distributed.enum_for(:each_updated_peer, r_root).to_a)
	remote.check_local_updated(r_root)

	assert(r_root.mission?)
	r_mission = remote_task(:id => 'mission')
	assert_equal([r_mission], r_root.children.to_a)
	assert_equal([], r_mission.children.to_a)
	assert_equal([], r_mission.event(:stop).child_objects(EventStructure::Signal).to_a)

	Roby::Control.synchronize do
	    r_next_mission = remote_task(:id => 'next_mission')
	    r_subtask = remote_task(:id => 'subtask')
	    assert(Distributed.keep?(r_mission))
	    assert(!Distributed.keep?(r_next_mission))
	    assert(!Distributed.keep?(r_subtask))
	end
	Roby.control.wait_one_cycle

	# Check that subscribing again is handled nicely
	assert_same(r_root, remote_peer.subscribe(r_root))
	assert_same(r_mission, remote_peer.subscribe(r_mission))
	r_subtask = remote_task(:id => 'subtask')
	r_next_mission = remote_task(:id => 'next_mission')
	assert(Distributed.keep?(r_subtask))
	assert(Distributed.keep?(r_next_mission))

	assert_equal([r_subtask], r_mission.children.to_a)
	proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	assert_equal(r_next_mission.event(:start), proxies.first)

	## Check plan GC after we have unsubscribed from mission
	Roby::Control.synchronize do
	    remote_peer.unsubscribe(r_mission)
	    assert(Distributed.keep?(r_mission))
	    assert(!remote_peer.subscribed?(r_mission))
	    assert(!Distributed.keep?(r_next_mission))
	    assert(!Distributed.keep?(r_subtask))
	end
	Roby.control.wait_one_cycle

	# Check that subtask and next_mission are removed from the plan
	assert(!r_subtask.plan)
	assert_raises(RemotePeerMismatch) { r_subtask.sibling_on(remote_peer) }
	subtask_proxy = remote_peer.proxies.find do |_, obj| 
	    obj == r_subtask || 
		(obj.root_object == r_subtask if obj.respond_to?(:root_object))
	end
	assert(!subtask_proxy)
	assert(!r_next_mission.plan)
	assert_raises(RemotePeerMismatch) { r_next_mission.sibling_on(remote_peer) }
	next_mission_proxy = remote_peer.proxies.find do |_, obj| 
	    obj == r_next_mission || 
		(obj.root_object == r_next_mission if obj.respond_to?(:root_object))
	end
	assert(!next_mission_proxy)
	# Check that mission is still included, and is still linked to root
	assert(r_mission.plan)
	assert(r_root.child_object?(r_mission, TaskStructure::Hierarchy))

	## Check that #subscribe takes the plan modification into account
	remote.remove_mission_subtask
	assert_same(r_mission, remote_peer.subscribe(r_mission))
	proxies = r_mission.children.to_a
	assert(proxies.empty?, proxies)
	proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	assert(Distributed.keep?(r_mission))
	assert(Distributed.keep?(r_mission.event(:stop)))
	assert_equal(1, proxies.size, proxies)
	r_next_mission_start = proxies.first
	assert(Distributed.keep?(r_next_mission_start))
	assert(Distributed.keep?(r_next_mission_start.task))

	## Re-add the child relation and test #unsubscribe
	remote_peer.unsubscribe(r_mission)
	remote.add_mission_subtask
	process_events
	assert(r_mission.children.empty?)

	r_mission = remote_peer.subscribe(r_mission)
	r_subtask = remote_task(:id => 'subtask')
	r_next_mission = remote_task(:id => 'next_mission')
	process_events
	proxies = r_mission.children.to_a
	assert(! proxies.empty?)
	proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	assert_equal(r_next_mission.event(:start), proxies.first)
    end

    def test_remove_not_needed
	peer2peer(true) do |remote|
	    left, right, middle =
		SimpleTask.new(:id => 'left'), 
		SimpleTask.new(:id => 'right'), 
		SimpleTask.new(:id => 'middle')
	    remote.plan.insert(left)
	    remote.plan.insert(right)

	    left.realized_by middle
	    right.realized_by middle

	    remote.singleton_class.class_eval do
		include Test::Unit::Assertions
		define_method(:remove_last_link) do
		    assert(left.update_on?(local_peer))
		    assert(middle.update_on?(local_peer))
		    left.remove_child(middle)
		end
	    end
	end

	left   = remote_peer.subscribe(remote_task(:id => 'left'))
	right  = remote_peer.subscribe(remote_task(:id => 'right'))
	middle = remote_task(:id => 'middle')

	assert(!middle.subscribed?)
	assert(Distributed.keep_object?(left))
	assert(Distributed.keep_object?(right))
	assert(Distributed.keep?(middle))

	Roby::Control.synchronize do
	    remote_peer.unsubscribe(right)
	    assert(!right.remotely_useful?)
	    assert(!right.subscribed?)
	    assert(!Distributed.keep?(right))
	    assert(Distributed.keep?(middle))
	end
	process_events
	assert(!right.plan)

	assert(middle.plan)
	assert_equal(1, middle.parent_objects(TaskStructure::Hierarchy).size)

	remote.remove_last_link
	process_events
	assert(!middle.plan)
    end

    def test_data_update
	peer2peer(true) do |remote|
	    task = SimpleTask.new(:id => 'task')
	    task.data = [4, 2]
	    remote.plan.insert(task)

	    remote.singleton_class.class_eval do 
		define_method(:change_data) { task.data = 42 }
	    end
	end
	task = remote_peer.local_object(remote_task(:id => 'task'))
	task = remote_peer.subscribe(task)
	assert_equal([4, 2], task.data)

	remote.change_data
	process_events
	assert_equal(42, task.data)
    end

    def test_plan_notifications
	peer2peer(true) do |remote|
	    plan.insert(mission = SimpleTask.new(:id => 'mission'))

	    remote.class.class_eval do
		define_method(:discard_mission) { remote.plan.discard(mission) }
		define_method(:insert_mission)  { remote.plan.insert(mission) }
	    end
	end
	r_mission = remote_peer.subscribe(remote_task(:id => 'mission'))
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
	peer2peer(true) do |remote|
	    mission, subtask, next_mission =
		SimpleTask.new(:id => 'mission'), 
		SimpleTask.new(:id => 'subtask'),
		SimpleTask.new(:id => 'next_mission')

	    remote.plan.insert(mission)
	    remote.plan.insert(next_mission)
	    remote.plan.permanent(subtask)

	    remote.singleton_class.class_eval do
		define_method(:add_mission_subtask) do
		    mission.realized_by subtask
		end
		define_method(:remove_mission_subtask) do
		    mission.remove_child subtask
		end
		define_method(:add_mission_stop_next_start) do
		    mission.on(:stop, next_mission, :start)
		end
		define_method(:remove_mission_stop_next_start) do
		    mission.event(:stop).remove_signal(next_mission.event(:start))
		end
	    end
	end

	r_mission	= remote_peer.subscribe(remote_task(:id => 'mission'))
	r_subtask 	= remote_peer.subscribe(remote_task(:id => 'subtask'))
	r_next_mission  = remote_peer.subscribe(remote_task(:id => 'next_mission'))

	# Check dynamic updates
	remote.add_mission_subtask
	process_events
	assert_equal([r_subtask], r_mission.children.to_a)

	remote.remove_mission_subtask
	process_events
	assert(r_mission.children.empty?)

	remote.add_mission_stop_next_start
	process_events
	assert_equal([r_next_mission.event(:start)], r_mission.event(:stop).child_objects(EventStructure::Signal).to_a)

	remote.remove_mission_stop_next_start
	process_events
	assert(r_mission.event(:stop).child_objects(EventStructure::Signal).empty?)
    end

    # Check that remote events that are unknown locally are properly ignored
    def test_ignored_events
	peer2peer(true) do |remote|
	    model = Class.new(SimpleTask) do
		event :unknown, :command => true
	    end
	    remote.plan.insert(t1 = SimpleTask.new(:id => 1))
	    remote.plan.insert(t2 = SimpleTask.new(:id => 2))
	    remote.plan.insert(u = model.new(:id => 0))

	    t1.event(:start).on u.event(:unknown)
	    t2.event(:start).emit_on u.event(:unknown)

	    remote.singleton_class.class_eval do
		define_method(:remove_relations) do
		    t1.event(:start).remove_signal u.event(:unknown)
		    u.event(:unknown).remove_forwarding t2.event(:start)
		end
	    end
	end

	u = remote_task(:id => 0)
	t1 = remote_task(:id => 1)
	t2 = remote_task(:id => 2)

	u = remote_peer.subscribe(u)
	assert(remote_peer.connected?)

	remote.remove_relations
	assert_nothing_raised { process_events }
	assert(remote_peer.connected?)
    end
end

