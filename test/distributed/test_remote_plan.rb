$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'distributed/common.rb'
require 'mockups/tasks'

# This testcase tests local views of remote plans
class TC_DistributedRemotePlan < Test::Unit::TestCase
    include DistributedTestCommon

    def teardown 
	Distributed.unpublish
	super
	Distributed.state = nil
    end



    # Check that we can query the remote plan database
    def test_query
	peer2peer do |remote|
	    mission, subtask = Task.new(:id => 1), Task.new(:id => 2)
	    mission.realized_by subtask
	    remote.plan.insert(mission)
	end

	# Get the remote missions
	r_missions = remote_peer.plan.missions
	assert_kind_of(ValueSet, r_missions)
	assert(r_missions.find { |t| t.arguments[:id] == 1 })

	# Get the remote tasks
	r_tasks = remote_peer.plan.known_tasks
	assert_equal([1, nil, 2].to_set, r_tasks.map { |t| t.arguments[:id] }.to_set)
    end

    def test_remote_proxy_update
	peer2peer do |remote|
	    remote.plan.insert(SimpleTask.new(:id => 'simple_task'))
	    remote.plan.discover(Task.new(:id => 'task'))
	    remote.plan.discover(SimpleTask.new(:id => 'other_task'))
	end

	proxy_model = Distributed.RemoteProxyModel(SimpleTask)
	assert(proxy_model.ancestors.include?(TaskProxy))

	r_simple_task = remote_task(:id => 'simple_task')
	r_task        = remote_task(:id => 'task')
	r_other_task  = remote_task(:id => 'other_task')

	proxy = remote_peer.proxy(r_simple_task)

	task = Task.new
	assert(proxy.read_only?)
	Distributed.update([proxy]) do
	    assert( !proxy.read_only?)
	    assert_nothing_raised do
		proxy.realized_by task
		proxy.remove_child task
		task.realized_by proxy
		task.remove_child proxy
	    end
	end
	assert(proxy.read_only?)

	assert_raises(NotOwner) { proxy.realized_by task }
	assert_raises(NotOwner) { task.realized_by proxy }
	Distributed.update([proxy]) { proxy.realized_by task }
	assert_nothing_raised { proxy.remove_child task }
	Distributed.update([proxy]) { task.realized_by proxy }
	assert_nothing_raised { task.remove_child proxy }

	other_proxy = proxy_model.new(remote_peer, r_other_task)
	assert_raises(NotOwner) { proxy.realized_by other_proxy }
	assert_raises(NotOwner) { other_proxy.realized_by proxy }
	Distributed.update([proxy, other_proxy]) { proxy.realized_by other_proxy }
	assert_raises(NotOwner) { proxy.remove_child other_proxy }
	Distributed.update([proxy, other_proxy]) { other_proxy.realized_by proxy }
	assert_raises(NotOwner) { other_proxy.remove_child proxy }
	apply_remote_command
    end

    def test_task_proxy
	peer2peer do |remote|
	    remote.plan.insert(SimpleTask.new(:id => 'simple_task'))
	    remote.plan.discover(Task.new(:id => 'task'))
	end

	proxy_model = Distributed.RemoteProxyModel(SimpleTask)
	assert(proxy_model.ancestors.include?(TaskProxy))

	r_simple_task = remote_task(:id => 'simple_task')
	r_task        = remote_task(:id => 'task')

	proxy = nil
	assert_nothing_raised { proxy = proxy_model.new(remote_peer, r_simple_task) }
	assert_raises(TypeError) { proxy_model.new(remote_peer, r_task) }
	local.plan.insert(proxy)

	assert(proxy = remote_peer.proxy(r_task))
	assert_equal(local.plan, proxy.plan)
	assert(remote_peer.owns?(proxy))
    end

    def assert_proxy_of(object, proxy)
	assert_kind_of(Roby::Distributed::RemoteObjectProxy, proxy)
	assert_equal(object.remote_object, proxy.remote_object(remote_peer.remote_id))
    end

    def test_event_proxy
	peer2peer do |remote|
	    remote.plan.discover(ev = EventGenerator.new(true))
	    remote.plan.discover(ev = EventGenerator.new(false))
	    remote.plan.discover(ev = EventGenerator.new { } )
	    remote.class.class_eval do
		define_method(:event_has_happened?) { ev.happened? }
	    end
	end
	assert_equal(3, remote_peer.plan.free_events.size)

	marshalled = remote_peer.plan.free_events
	marshalled.each { |ev| assert_kind_of(Roby::Distributed::MarshalledEventGenerator, ev) }

	all_events = marshalled.map { |ev| remote_peer.proxy(ev) }
	all_events.each { |ev| assert_kind_of(Roby::Distributed::EventGeneratorProxy, ev) }
	
	assert_equal(1, all_events.find_all { |ev| !ev.controlable? }.size)
	assert_equal(2, all_events.find_all { |ev| ev.controlable? }.size)
    end

    # Test that the remote plan structure is properly mapped to the local
    # plan database
    def test_discover_neighborhood
	peer2peer do |remote|
	    mission, subtask, next_mission =
		Task.new(:id => 'mission'), 
		Task.new(:id => 'subtask'),
		Task.new(:id => 'next_mission')
	    mission.realized_by subtask
	    mission.on(:stop, next_mission, :start)

	    remote.plan.insert(mission)
	    remote.plan.insert(next_mission)
	end

	r_mission = remote_task(:id => 'mission')
	r_subtask = remote_task(:id => 'subtask')
	r_next_mission = remote_task(:id => 'next_mission')

	proxy = remote_peer.proxy(r_mission)

	# We don't know about the remote relations
	assert_equal([], proxy.child_objects(TaskStructure::Hierarchy).to_a)
	assert_equal([], proxy.event(:stop).child_objects(EventStructure::Signal).to_a)

	# Discover remote relations
	remote_peer.discover_neighborhood(proxy.remote_object(remote_peer.remote_id), 1)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert_equal(1, proxies.size)
	    assert_proxy_of(r_subtask, proxies.first)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end
    end

    def test_subscribe
	peer2peer do |remote|
	    root, mission, subtask, next_mission =
		Task.new(:id => 'root'), 
		Task.new(:id => 'mission'), 
		Task.new(:id => 'subtask'),
		Task.new(:id => 'next_mission')
	    root.realized_by mission
	    mission.realized_by subtask
	    mission.on(:stop, next_mission, :start)

	    remote.plan.insert(root)
	    remote.plan.insert(mission)
	    remote.plan.insert(next_mission)
	end

	r_root = remote_task(:id => 'root')
	proxy_root = remote_peer.proxy(r_root)
	r_mission = remote_task(:id => 'mission')
	proxy = remote_peer.proxy(r_mission)
	r_subtask = remote_task(:id => 'subtask')
	r_next_mission = remote_task(:id => 'next_mission')

	# Check that #subscribe updates the relations between subscribed objects
	remote_peer.subscribe(r_root)
	apply_remote_command do
	    assert(local.plan.mission?(proxy_root))
	    assert_equal([proxy], proxy_root.child_objects(TaskStructure::Hierarchy).to_a)
	    assert_equal([], proxy.child_objects(TaskStructure::Hierarchy).to_a)
	    assert_equal([], proxy.event(:stop).child_objects(EventStructure::Signal).to_a)
	end

	remote_peer.subscribe(r_mission)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert_proxy_of(r_subtask, proxies.first)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end

	## Check that #unsubscribe(..., false) disables dynamic updates
	remote_peer.unsubscribe(r_mission, false)
	apply_remote_command
	r_mission.remote_object.remove_child(r_subtask.remote_object)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert_proxy_of(r_subtask, proxies.first)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end

	## Check that #subscribe removes old relations as well
	remote_peer.subscribe(r_mission)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert(proxies.empty?)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end

	## Re-add the child relation and test #unsubscribe
	remote_peer.unsubscribe(r_mission, false)
	apply_remote_command
	r_mission.remote_object.realized_by(r_subtask.remote_object)
	remote_peer.subscribe(r_mission)
	remote_peer.subscribe(r_subtask)
	apply_remote_command do
	    assert(!local.plan.mission?(remote_peer.proxy(r_subtask)))
	    assert(remote_peer.subscribed?(r_mission.remote_object))
	    assert(remote_peer.subscribed?(r_subtask.remote_object))
	end

	remote_peer.unsubscribe(r_subtask, true)
	apply_remote_command do
	    assert(! remote_peer.subscribed?(r_subtask.remote_object))
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert(! proxies.empty?)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end

	remote_peer.unsubscribe(r_mission, true)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert(proxies.empty?)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal([], proxies)
	end
    end

    def test_plan_notifications
	peer2peer do |remote|
	    root, mission, subtask, next_mission =
		Task.new(:id => 'root'), 
		Task.new(:id => 'mission'), 
		Task.new(:id => 'subtask')

	    root.realized_by mission
	    mission.realized_by subtask

	    remote.plan.insert(root)
	    remote.plan.insert(mission)

	    remote.class.class_eval do
		define_method(:remove_subtask) { remote.plan.remove_object(subtask) }
		define_method(:discard_mission) { remote.plan.discard(mission) }
		define_method(:remove_mission) { remote.plan.remove_object(mission) }
	    end
	end
	r_root		= remote_task(:id => 'root')
	proxy_root	= remote_peer.proxy(r_root)
	r_mission	= remote_task(:id => 'mission')
	proxy		= remote_peer.proxy(r_mission)
	r_subtask	= remote_task(:id => 'subtask')

	remote_peer.subscribe(r_root)
	remote_peer.subscribe(r_mission)
	remote_peer.subscribe(r_subtask)
	apply_remote_command
	assert_equal(4, local.plan.size)

	remote.remove_subtask
	apply_remote_command
	assert(!remote_peer.subscribed?(r_subtask.remote_object), remote_peer.subscriptions.inspect)
	assert_equal(3, local.plan.size)
	assert(!local.plan.known_tasks.find { |t| t.arguments[:id] == 'subtask' })

	remote.discard_mission
	apply_remote_command
	assert_equal(3, local.plan.size)
	assert(local.plan.mission?(proxy))
    end

    def test_relation_updates
	peer2peer do |remote|
	    mission, subtask, next_mission =
		Task.new(:id => 'mission'), 
		Task.new(:id => 'subtask'),
		Task.new(:id => 'next_mission')
	    mission.realized_by subtask
	    mission.on(:stop, next_mission, :start)

	    remote.plan.insert(mission)
	    remote.plan.insert(next_mission)
	end

	r_mission = remote_task(:id => 'mission')
	r_subtask = remote_task(:id => 'subtask')
	r_next_mission = remote_task(:id => 'next_mission')
	proxy	       = remote_peer.proxy(r_mission)

	remote_peer.plan.known_tasks.each do |t|
	    remote_peer.subscribe(t)
	end

	# Check dynamic updates
	r_mission.remote_object.realized_by(r_subtask.remote_object)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert_proxy_of(r_subtask, proxies.first)
	end

	r_mission.remote_object.remove_child(r_subtask.remote_object)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert(proxies.empty?)
	end

	r_mission.remote_object.event(:stop).remote_object.add_signal(r_next_mission.remote_object.event(:start).remote_object)
	apply_remote_command do
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end

	r_mission.remote_object.event(:stop).remote_object.remove_signal(r_next_mission.remote_object.event(:start).remote_object)
	apply_remote_command do
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert(proxies.empty?)
	end
    end
end

