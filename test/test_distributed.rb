require 'test_config'
require 'mockups/tasks'
require 'roby/distributed/connection_space'
require 'roby/distributed/proxy'

class TC_Distributed < Test::Unit::TestCase
    include Roby
    include Roby::Distributed
    include Rinda

    def setup
	Thread.abort_on_exception = true
    end

    def teardown 
	Distributed.unpublish
	Distributed.state = nil
	DRb.stop_service if DRb.thread
	stop_remote_process
    end

    attr_reader :remote_pid, :quit_r, :quit_w
    def remote_process
	start_r, start_w= IO.pipe
	@quit_r,  @quit_w = IO.pipe
	@remote_pid = fork do
	    start_r.close
	    yield
	    start_w.write('OK')
	    quit_r.read(2)
	end
	start_w.close
	start_r.read(2)

    ensure
	start_r.close
    end
    
    def stop_remote_process
	if remote_pid
	    quit_w.write('OK') 
	    Process.waitpid(remote_pid)
	end
	@remote_pid = nil
    end

    def assert_has_neighbour(&check)
	Distributed.state.start_neighbour_discovery
	Distributed.state.wait_discovery

	assert(!Distributed.state.discovering?)
	assert(1, Distributed.neighbours.size)
	assert(Distributed.neighbours.find(&check))
    end

    # Test neighbour discovery using a local tuplespace as the neighbour list. This is
    # mainly useful for testing purposes
    def test_centralized_local_discovery
	central_tuplespace = TupleSpace.new

	remote = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	Distributed.state = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	assert_has_neighbour { |n| n.tuplespace == remote }
    end

    # Test neighbour discovery using a remote central tuplespace as neighbour list
    def test_centralized_drb_discovery
	central_tuplespace = TupleSpace.new
	DRb.start_service 'druby://localhost:1245', central_tuplespace

	remote_process do
	    DRb.stop_service
	    DRb.start_service
	    central_tuplespace = DRbObject.new_with_uri('druby://localhost:1245')

	    Distributed.state = ConnectionSpace.new :ring_discovery => false, 
		:discovery_tuplespace => central_tuplespace
	end
	Distributed.state = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace
	assert_has_neighbour { |n| n.name == "#{Socket.gethostname}-#{remote_pid}" }
    end

    BROADCAST = (1..10).map { |i| "127.0.0.#{i}" }
    # Test neighbour discovery using UDP for discovery
    def test_ringserver_discovery
	remote_process do
	    DRb.start_service
	    Distributed.state = ConnectionSpace.new :period => 0.5, :ring_discovery => true, :ring_broadcast => BROADCAST
	    Distributed.publish :bind => '127.0.0.2'
	end

	DRb.start_service
	Distributed.state = ConnectionSpace.new :period => 0.5, :ring_discovery => true, :ring_broadcast => BROADCAST
	Distributed.publish :bind => '127.0.0.1'

	assert_has_neighbour { |n| n.name == "#{Socket.gethostname}-#{remote_pid}" }
    end

    # Test establishing peer-to-peer connection between two ConnectionSpace objects
    def test_connection
	central_tuplespace = TupleSpace.new

	remote = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace, :name => "remote"
	local   = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace, :name => 'local'
	Distributed.state = local

	# Initiate the connection from +local+ and check we did ask for
	# connection on +remote+
	local.start_neighbour_discovery(true)
	n_remote = Distributed.neighbours.find { true }
	p_remote = Peer.new(local, n_remote)
	assert_equal(local,  p_remote.keepalive['tuplespace'])
	assert_equal(remote, p_remote.neighbour.tuplespace)
	assert_nothing_raised { remote.read(p_remote.keepalive.value, 0) }
	# The connection is not alive yet since +remote+ does not have
	# finalized the handshake yet
	assert(! p_remote.connected?)
	assert(! p_remote.alive?)

	# After +remote+ has finished neighbour discovery, all connection
	# attempts should have been finalized, so we should have a Peer object
	# for +local+
	remote.start_neighbour_discovery(true)
	p_local = remote.peers.find { |_, p_local| p_local.neighbour.tuplespace == local }
	assert(p_local)
	p_local = p_local.last
	assert_equal(remote, p_local.keepalive['tuplespace'])
	assert_equal(local,  p_local.neighbour.tuplespace)
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
    end

    # Establishes a peer to peer connection between two ConnectionSpace objects
    def peer2peer
	central_tuplespace = TupleSpace.new
	remote = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace, :name => "remote",
	    :plan => Plan.new

	local   = ConnectionSpace.new :ring_discovery => false, 
	    :discovery_tuplespace => central_tuplespace, :name => 'local',
	    :plan => Plan.new

	local.start_neighbour_discovery(true)
	n_remote = local.neighbours.find { true }
	p_remote = Peer.new(local, n_remote)
	remote.start_neighbour_discovery(true)
	local.start_neighbour_discovery(true)
	p_local = remote.peers.find { true }.last

	return [remote, p_remote, local, p_local]
    end

    # Check that we can query the remote plan database
    def test_query
	remote, p_remote, local, p_local = peer2peer
	mission, subtask = Task.new, Task.new
	mission.realized_by subtask
	remote.plan.insert(mission)

	# Get the remote missions
	r_missions = p_remote.plan.missions
	assert_equal([mission].to_a, r_missions.to_a)

	# Get the remote tasks
	r_missions = p_remote.plan.known_tasks
	assert_equal([mission, subtask].to_set, r_missions.to_set)
    end

    def test_remote_proxy
	remote, remote_peer, local, local_peer = peer2peer

	proxy_model = Distributed.RemoteProxyModel(SimpleTask)
	assert(proxy_model.ancestors.include?(TaskProxy))

	remote_task = SimpleTask.new
	remote.plan.insert(remote_task)

	proxy = nil
	assert_nothing_raised { proxy = proxy_model.new(remote_peer, remote_task) }
	assert_raises(TypeError) { proxy_model.new(remote_peer, Task.new) }
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

	assert_raises(InvalidRemoteOperation) { proxy.realized_by task }
	assert_raises(InvalidRemoteOperation) { task.realized_by proxy }
	proxy.update { proxy.realized_by task }
	assert_nothing_raised { proxy.remove_child task }
	proxy.update { task.realized_by proxy }
	assert_nothing_raised { task.remove_child proxy }

	other_proxy = proxy_model.new(remote_peer, SimpleTask.new)
	assert_raises(InvalidRemoteOperation) { proxy.realized_by other_proxy }
	assert_raises(InvalidRemoteOperation) { other_proxy.realized_by proxy }
	proxy.update { other_proxy.update { proxy.realized_by other_proxy } }
	assert_raises(InvalidRemoteOperation) { proxy.remove_child other_proxy }
	proxy.update { other_proxy.update { other_proxy.realized_by proxy } }
	assert_raises(InvalidRemoteOperation) { other_proxy.remove_child proxy }

	# Test Peer#proxy
	task = Task.new
	assert(proxy = remote_peer.proxy(task))
	assert_equal(local.plan, proxy.plan)
	assert_equal([remote_peer], proxy.owners)
    end

    attr_reader :remote, :p_remote, :local, :p_local
    def apply_remote_command
	# flush the command queue
	loop do
	    did_something = p_remote.flush
	    did_something ||= p_local.flush
	    break unless did_something
	end
	# make the remote host actually apply the commands
	remote.start_neighbour_discovery(true)
	# read the result
	local.start_neighbour_discovery(true)
	yield
    end
    def assert_proxy_of(object, proxy)
	assert_equal(object, proxy.remote_object)
    end

    # Test that the remote plan structure is properly mapped to the local
    # plan database
    def test_structure_discovery
	@remote, @p_remote, @local, @p_local = peer2peer
	mission, subtask, next_mission = (1..3).map { Task.new }
	Distributed.state = remote

	mission.realized_by subtask
	remote.plan.insert(mission)
	r_mission = p_remote.plan.missions.find { true }

	proxy = p_remote.proxy(r_mission)
	mission.on(:stop, next_mission, :start)
	remote.plan.insert(next_mission)

	# We don't know about the remote relations
	assert_equal([], proxy.enum_for(:each_child_object, Roby::TaskStructure::Hierarchy).to_a)
	assert_equal([], proxy.event(:stop).enum_for(:each_child_object, Roby::EventStructure::Signal).to_a)

	# Discover remote relations
	p_remote.discover_neighborhood(r_mission, 1)
	apply_remote_command do
	    proxies = proxy.enum_for(:each_child_object, Roby::TaskStructure::Hierarchy).to_a
	    assert_proxy_of(subtask, proxies.first)
	    proxies = proxy.event(:stop).enum_for(:each_child_object, Roby::EventStructure::Signal).to_a
	    assert_equal(p_remote.proxy(next_mission).event(:start), proxies.first)
	end

	# Check that #subscribe updates the relations between subscribed objects
	proxy.clear_relations
	p_remote.subscribe(r_mission)
	apply_remote_command do
	    assert_equal([], proxy.enum_for(:each_child_object, Roby::TaskStructure::Hierarchy).to_a)
	    assert_equal([], proxy.event(:stop).enum_for(:each_child_object, Roby::EventStructure::Signal).to_a)
	end

	p_remote.plan.known_tasks.each do |t|
	    p_remote.subscribe(t)
	end
	apply_remote_command do
	    proxies = proxy.enum_for(:each_child_object, Roby::TaskStructure::Hierarchy).to_a
	    assert_proxy_of(subtask, proxies.first)
	    proxies = proxy.event(:stop).enum_for(:each_child_object, Roby::EventStructure::Signal).to_a
	    assert_equal(p_remote.proxy(next_mission).event(:start), proxies.first)
	end

	# Check that #subscribe removes old relations as well
	p_remote.unsubscribe(subtask, false)
	mission.remove_child(subtask)
	p_remote.subscribe(subtask)
	apply_remote_command do
	    proxies = proxy.enum_for(:each_child_object, Roby::TaskStructure::Hierarchy).to_a
	    assert(proxies.empty?)
	end

	# Check dynamic updates
	mission.realized_by(subtask)
	apply_remote_command do
	    proxies = proxy.enum_for(:each_child_object, Roby::TaskStructure::Hierarchy).to_a
	    assert_proxy_of(subtask, proxies.first)
	end

	mission.remove_child(subtask)
	apply_remote_command do
	    proxies = proxy.enum_for(:each_child_object, Roby::TaskStructure::Hierarchy).to_a
	    assert(proxies.empty?)
	end

	mission.event(:stop).remove_signal(next_mission.event(:start))
	apply_remote_command do
	    proxies = proxy.event(:stop).enum_for(:each_child_object, Roby::EventStructure::Signal).to_a
	    assert(proxies.empty?)
	end

	mission.event(:stop).add_signal(next_mission.event(:start))
	apply_remote_command do
	    proxies = proxy.event(:stop).enum_for(:each_child_object, Roby::EventStructure::Signal).to_a
	    assert_equal(p_remote.proxy(next_mission).event(:start), proxies.first)
	end

	p_remote.unsubscribe(subtask, true)
	apply_remote_command do
	    proxies = proxy.enum_for(:each_child_object, Roby::TaskStructure::Hierarchy).to_a
	    assert(proxies.empty?)
	end
    end
end

