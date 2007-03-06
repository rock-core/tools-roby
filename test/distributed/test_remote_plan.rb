$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'

# This testcase tests local views of remote plans
class TC_DistributedRemotePlan < Test::Unit::TestCase
    include Roby::Distributed::Test

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
	Distributed.update([r_simple_task]) do
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
	Distributed.update([r_simple_task]) { r_simple_task.realized_by task }
	assert_nothing_raised { r_simple_task.remove_child task }
	Distributed.update([r_simple_task]) { task.realized_by r_simple_task }
	assert_nothing_raised { task.remove_child r_simple_task }

	assert_raises(NotOwner) { r_simple_task.realized_by r_other_task }
	assert_raises(NotOwner) { r_other_task.realized_by r_simple_task }
	Distributed.update([r_simple_task, r_other_task]) { r_simple_task.realized_by r_other_task }
	assert_raises(NotOwner) { r_simple_task.remove_child r_other_task }
	Distributed.update([r_simple_task, r_other_task]) do
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
	assert_raises(TypeError) { proxy_model.new(remote_peer, r_task) }

	assert(proxy = remote_peer.proxy(r_task))
	assert_equal(proxy.remote_object(remote_peer), r_task.remote_object(remote_peer))
	assert_equal(local.plan, proxy.plan)
	assert(remote_peer.owns?(proxy))
    end

    # Check that remote events that are unknown locally are properly ignored
    def test_ignored_events
	peer2peer do |remote|
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
	    proxies = r_mission.children.to_a
	    assert_equal(1, proxies.size)
	    assert_equal(r_subtask, proxies.first)
	    proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(r_next_mission.event(:start), proxies.first)
	end

	process_events
	assert_equal([remote_peer.task], plan.keepalive.to_a)
    end

    def test_subscribe
	peer2peer do |remote|
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
		define_method(:remove_mission_subtask) do
		    mission.remove_child subtask
		end
		define_method(:add_mission_subtask) do
		    mission.realized_by subtask
		end
	    end
	end

	r_root = remote_task(:id => 'root')
	r_mission = remote_task(:id => 'mission')
	r_subtask = remote_task(:id => 'subtask')
	r_next_mission = remote_task(:id => 'next_mission')

	# Check that #subscribe updates the relations between subscribed objects
	r_root = remote_peer.subscribe(r_root)
	assert(r_root.mission?)
	assert_equal([r_mission], r_root.children.to_a)
	assert_equal([], r_mission.children.to_a)
	assert_equal([], r_mission.event(:stop).child_objects(EventStructure::Signal).to_a)

	# Check that subscribing again is handled nicely
	r_root = remote_peer.subscribe(r_root)
	r_mission = remote_peer.subscribe(r_mission)
	assert_equal([r_subtask].to_value_set, r_mission.children)
	proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	assert_equal(r_next_mission.event(:start), proxies.first)

	## Check that #unsubscribe(..., false) disables dynamic updates
	remote_peer.unsubscribe(r_mission)
	assert(!remote_peer.subscribed?(r_mission))
	remote.remove_mission_subtask

	## Check that #subscribe removes old relations as well
	r_mission = remote_peer.subscribe(r_mission)
	proxies = r_mission.children.to_a
	assert(proxies.empty?, proxies)
	proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	assert(Distributed.needed?(r_mission))
	assert(Distributed.needed?(r_mission.event(:stop)))
	assert_equal(1, proxies.size, proxies)
	r_next_mission_start = proxies.first
	assert(Distributed.needed?(r_next_mission_start))
	assert(Distributed.needed?(r_next_mission_start.task))

	## Re-add the child relation and test #unsubscribe
	remote_peer.unsubscribe(r_mission)
	remote.add_mission_subtask
	r_mission = remote_peer.subscribe(r_mission)
	r_subtask = remote_peer.subscribe(r_subtask)
	assert(!local.plan.mission?(r_subtask))
	assert(remote_peer.subscribed?(r_mission))
	assert(remote_peer.subscribed?(r_subtask))

	remote_peer.unsubscribe(r_subtask)
	assert(! remote_peer.subscribed?(r_subtask))
	proxies = r_mission.children.to_a
	assert(! proxies.empty?)
	proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	assert_equal(r_next_mission.event(:start), proxies.first)

	remote_peer.unsubscribe(r_mission)
	process_events
	proxies = r_mission.children.to_a
	assert(proxies.empty?)
	proxies = r_mission.event(:stop).child_objects(EventStructure::Signal).to_a
	assert_equal([], proxies)
    end

    def test_remove_not_needed
	peer2peer do |remote|
	    left, right, middle =
		SimpleTask.new(:id => 'left'), 
		SimpleTask.new(:id => 'right'), 
		SimpleTask.new(:id => 'middle')
	    remote.plan.insert(left)
	    remote.plan.insert(right)

	    left.realized_by middle
	    right.realized_by middle

	    remote.singleton_class.class_eval do
		define_method(:remove_last_link) do
		    left.remove_child(middle)
		end
	    end
	end

	left   = remote_peer.local_object(remote_task(:id => 'left'))
	right  = remote_peer.local_object(remote_task(:id => 'right'))
	left  = remote_peer.subscribe(left)
	right = remote_peer.subscribe(right)

	assert(middle = local.plan.known_tasks.find { |t| t.arguments[:id] == 'middle' })
	assert(!middle.subscribed?)
	remote_peer.unsubscribe(right)
	process_events
	assert(!right.plan)

	assert(middle = local.plan.known_tasks.find { |t| t.arguments[:id] == 'middle' })
	assert_equal(1, middle.parent_objects(TaskStructure::Hierarchy).size)

	remote.remove_last_link
	process_events
	assert(!middle.plan)
    end

    def test_data_update
	peer2peer do |remote|
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
	assert_happens(5, "data update") do
	    assert_equal(42, task.data)
	end
    end

    def test_plan_notifications
	peer2peer do |remote|
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
	peer2peer do |remote|
	    mission, subtask, next_mission =
		SimpleTask.new(:id => 'mission'), 
		SimpleTask.new(:id => 'subtask'),
		SimpleTask.new(:id => 'next_mission')
	    mission.realized_by subtask
	    mission.on(:stop, next_mission, :start)

	    remote.plan.insert(mission)
	    remote.plan.insert(next_mission)

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

    def test_unknown_event
	peer2peer do |remote|
	    model = Class.new(SimpleTask) do
		event :unknown_event
	    end

	    remote.plan.insert(root = model.new(:id => 1))
	    root.realized_by(child = SimpleTask.new(:id => 2))
	    root.on(:unknown_event, child, :start)
	end

	r_unknown = remote_task(:id => 1)
	assert_kind_of(SimpleTask, r_unknown)

	r_unknown = remote_peer.subscribe(r_unknown)
	r_child = r_unknown.children.find { true }
	assert(r_child.parent_objects(EventStructure::Signal).empty?)
    end
end

