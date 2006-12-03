$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'distributed/common.rb'
require 'mockups/tasks'

class TC_DistributedStructureMapping < Test::Unit::TestCase
    include DistributedTestCommon

    def teardown 
	Distributed.unpublish
	Distributed.state = nil

	super
    end

    # Test establishing peer-to-peer connection between two ConnectionSpace objects
    def test_connection
	start_peers

	# Initiate the connection from +local+ and check we did ask for
	# connection on +remote+
	local.start_neighbour_discovery(true)
	n_remote = Distributed.neighbours.find { true }
	p_remote = Peer.new(local, n_remote)
	assert_equal(local,  p_remote.keepalive['connection_space'])
	assert_equal(remote, p_remote.neighbour.connection_space)
	assert_nothing_raised { remote.read(p_remote.keepalive.value, 0) }
	# The connection is not alive yet since +remote+ does not have
	# finalized the handshake yet
	assert(! p_remote.connected?)
	assert(! p_remote.alive?)

	# After +remote+ has finished neighbour discovery, all connection
	# attempts should have been finalized, so we should have a Peer object
	# for +local+
	remote.start_neighbour_discovery(true)
	p_local = remote.peers.find { true }.last
	assert_equal(local, p_local.neighbour.connection_space)
	assert_equal(remote, p_local.keepalive['connection_space'])
	assert_equal(local,  p_local.neighbour.connection_space)
	assert_nothing_raised { local.read(p_local.keepalive.value, 0) }

	assert(p_local.connected?)
	assert(p_local.alive?)
	# p_remote is still not alive since +local+ does not know the
	# connection is finalized
	assert(! p_remote.alive?)
	assert(! p_remote.connected?)

	# Finalize the connection
	local.start_neighbour_discovery(true)
	assert(p_remote.connected?)
	assert(p_remote.alive?)

	assert_equal('remote', p_remote.neighbour.name)
	assert_equal('remote', p_remote.remote_server.client_name)
	assert_equal('local', p_remote.remote_server.server_name)
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
	assert_equal(1, r_missions.find { true }.arguments[:id])

	# Get the remote tasks
	r_tasks = remote_peer.plan.known_tasks
	assert_equal([1, 2].to_set, r_tasks.map { |t| t.arguments[:id] }.to_set)
    end

    def test_remote_proxy
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

	proxy = nil
	assert_nothing_raised { proxy = proxy_model.new(remote_peer, r_simple_task) }
	assert_raises(TypeError) { proxy_model.new(remote_peer, r_task) }
	local.plan.insert(proxy)

	task = Task.new
	assert(proxy.read_only?)
	proxy.update do
	    assert( !proxy.read_only?)
	    assert_nothing_raised do
		proxy.realized_by task
		proxy.remove_child task
		task.realized_by proxy
		task.remove_child proxy
	    end
	end

	assert_raises(InvalidRemoteTaskOperation) { proxy.realized_by task }
	assert_raises(InvalidRemoteTaskOperation) { task.realized_by proxy }
	proxy.update { proxy.realized_by task }
	assert_nothing_raised { proxy.remove_child task }
	proxy.update { task.realized_by proxy }
	assert_nothing_raised { task.remove_child proxy }

	other_proxy = proxy_model.new(remote_peer, r_other_task)
	assert_raises(InvalidRemoteTaskOperation) { proxy.realized_by other_proxy }
	assert_raises(InvalidRemoteTaskOperation) { other_proxy.realized_by proxy }
	proxy.update { other_proxy.update { proxy.realized_by other_proxy } }
	assert_raises(InvalidRemoteTaskOperation) { proxy.remove_child other_proxy }
	proxy.update { other_proxy.update { other_proxy.realized_by proxy } }
	assert_raises(InvalidRemoteTaskOperation) { other_proxy.remove_child proxy }

	# Test Peer#proxy
	assert(proxy = remote_peer.proxy(r_task))
	assert_equal(local.plan, proxy.plan)
	assert(remote_peer.owns?(proxy))
    end

    def assert_proxy_of(object, proxy)
	assert_kind_of(Roby::Distributed::RemoteObjectProxy, proxy)
	assert_equal(object.remote_object, proxy.remote_object(remote_peer.remote_id))
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
	    assert_proxy_of(r_subtask, proxies.first)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end
    end

    def test_subscribe
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
	# Check that #subscribe updates the relations between subscribed objects
	remote_peer.subscribe(r_mission)
	apply_remote_command do
	    assert_equal([], proxy.child_objects(TaskStructure::Hierarchy).to_a)
	    assert_equal([], proxy.event(:stop).child_objects(EventStructure::Signal).to_a)
	end

	remote_peer.plan.known_tasks.each do |t|
	    remote_peer.subscribe(t)
	end
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert_proxy_of(r_subtask, proxies.first)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end

	## Check that #unsubscribe(..., false) disables dynamic updates
	remote_peer.unsubscribe(r_subtask, false)
	apply_remote_command
	r_mission.remote_object.remove_child(r_subtask.remote_object)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert_proxy_of(r_subtask, proxies.first)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end

	## Check that #subscribe removes old relations as well
	remote_peer.subscribe(r_subtask)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert(proxies.empty?)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end

	## Re-add the child relation and test #unsubscribe
	remote_peer.unsubscribe(r_subtask, false)
	apply_remote_command
	r_mission.remote_object.realized_by(r_subtask.remote_object)
	remote_peer.subscribe(r_subtask)
	remote_peer.unsubscribe(r_subtask, true)
	apply_remote_command do
	    proxies = proxy.child_objects(TaskStructure::Hierarchy).to_a
	    assert(proxies.empty?)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal(remote_peer.proxy(r_next_mission).event(:start), proxies.first)
	end

	remote_peer.unsubscribe(r_mission, true)
	apply_remote_command do
	    proxies = proxy.parent_objects(TaskStructure::Hierarchy).to_a
	    assert(proxies.empty?)
	    proxies = proxy.event(:stop).child_objects(EventStructure::Signal).to_a
	    assert_equal([], proxies)
	end
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

