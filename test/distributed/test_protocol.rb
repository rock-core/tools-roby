require 'roby/test/distributed'
require 'roby/tasks/simple'

class TC_DistributedRobyProtocol < Minitest::Test
    def test_remote_id
	remote = remote_server do
	    def remote_object
		@object ||= Object.new
		@object.remote_id
	    end
	end

	assert_equal(remote.remote_object, remote.remote_object)

	h = Hash.new
	h[remote.remote_object] = 1
	assert_equal(1, h[remote.remote_object])

	s = Set.new
	s << remote.remote_object
	assert(s.include?(remote.remote_object))

	object = Object.new
	assert_equal(object, object.remote_id.local_object)
    end

    TEST_ARRAY_SIZE = 7
    def dumpable_array
	task = Tasks::Simple.new(:id => 1)
	[1, task, 
	    Roby::EventGenerator.new {}, 
	    Tasks::Simple.new(:id => 2), 
	    task.event(:start), 
	    Roby::TaskStructure::Hierarchy, 
	    Tasks::Simple.new_submodel.new(:id => 3) ]
    end
    def dumpable_hash
	Hash[*(0...TEST_ARRAY_SIZE).zip(dumpable_array).flatten]
    end
    def check_undumped_array(array, recursive = true)
	assert_equal(TEST_ARRAY_SIZE, array.size)
	assert_equal(1, array[0])

	assert_kind_of(Task::DRoby, array[1])
	assert_equal({:id => 1}, array[1].arguments)
	assert_equal(Tasks::Simple, array[1].model.proxy(remote_peer))

	assert_kind_of(EventGenerator::DRoby, array[2])
	assert(array[2].controlable)
	assert_equal(EventGenerator, array[2].model.proxy(remote_peer))

	assert_kind_of(Task::DRoby, array[3])
	assert_equal({:id => 2}, array[3].arguments)
	assert_equal(Tasks::Simple, array[3].model.proxy(remote_peer))

	assert_kind_of(TaskEventGenerator::DRoby, array[4])
	assert_equal(array[1].remote_siblings, array[4].task.remote_siblings)
	assert_equal(:start, array[4].symbol)

	assert_kind_of(Roby::Distributed::DRobyConstant, array[5])
	assert_equal(Roby::TaskStructure::Hierarchy.object_id, array[5].proxy(nil).object_id)

	assert_kind_of(Task::DRoby, array[6])
	refute_equal(Task, array[6].model.proxy(remote_peer))

	array.each do |element|
	    Marshal.dump(element)
	end
	dumped = nil
	dumped = Marshal.dump(array)
    
	if recursive
	    check_undumped_array(Marshal.load(dumped), false)
	end
    end

    def test_array_droby_dump
	FlexMock.use do |mock|
	    mock.should_receive(:droby_dump).and_return("mock")
	    array = [1, mock]
	    assert_equal([1, "mock"], array.droby_dump(nil))
	end
    end

    def test_set_droby_dump
	FlexMock.use do |mock|
	    mock.should_receive(:droby_dump).and_return("mock")
	    set = [1, mock, "q"].to_set
	    assert_equal([1, "mock", "q"].to_set, set.droby_dump(nil))
	end
    end

    def test_hash_droby_dump
	FlexMock.use do |mock|
	    mock.should_receive(:droby_dump).and_return("mock")
	    hash = { 1 => mock, mock => "q" }
	    assert_equal({ 1 => "mock", "mock" => "q" }, hash.droby_dump(nil))
	end
    end

    def test_value_set_droby_dump
	FlexMock.use do |mock|
	    mock.should_receive(:droby_dump).and_return("mock")
	    value_set = [1, mock, "q"].to_value_set


	    dumped = value_set.droby_dump(nil)
	    assert_kind_of(ValueSet, dumped)
	    assert_equal([1, "mock", "q"].to_set, dumped.to_set)
	end
    end


    def test_enumerables
	test_case = self
	peer2peer do |remote|
	    PeerServer.class_eval do
		define_method(:array)     { test_case.dumpable_array }
		define_method(:value_set) { test_case.dumpable_array.to_value_set }
		define_method(:_hash)     { test_case.dumpable_hash }
		define_method(:array_of_array) { [test_case.dumpable_array] }
	    end
	end

	array = remote_peer.call(:array)
	assert_kind_of(Array, array)
	check_undumped_array(array)

	hash = remote_peer.call(:_hash)
	assert_kind_of(Hash, hash)
	check_undumped_array(hash)

	array_of_array = remote_peer.call(:array_of_array)
	assert_kind_of(Array, array_of_array)
	check_undumped_array(array_of_array[0])

	set = remote_peer.call(:value_set)
	assert_kind_of(ValueSet, set)
	assert_equal(TEST_ARRAY_SIZE, set.size)
	assert(set.find { |o| o == 1 })
	assert(set.find { |t| t.kind_of?(Task::DRoby) && t.arguments[:id] == 1 })
	assert(set.find { |e| e.kind_of?(EventGenerator::DRoby) })
	assert(set.find { |t| t.kind_of?(Task::DRoby) && t.arguments[:id] == 2 })
    end

    def test_marshal_peer
	peer2peer do |remote|
	    def remote.remote_peer_id; Distributed.state.remote_id end
	end

	m_local = remote_peer.call(:peer)
	assert_equal(Distributed.remote_id, m_local.peer_id)
	assert_equal(Roby::Distributed, m_local.proxy(nil))
	assert_equal(remote_peer.remote_id, remote.remote_peer_id)
    end

    def test_marshal_model
	peer2peer do |remote|
	    PeerServer.class_eval do
		def model; Tasks::Simple end
		def anonymous_model; @anonymous ||= model.new_submodel end
		def check_anonymous_model(remote_model)
		    @anonymous == peer.local_object(remote_model)
		end
	    end
	end

	assert_equal(Tasks::Simple, remote_peer.call(:model).proxy(remote_peer))

	anonymous = remote_peer.call(:anonymous_model).proxy(remote_peer)
	refute_same(anonymous, Tasks::Simple)
	assert(anonymous < Tasks::Simple)
	assert(remote_peer.call(:check_anonymous_model, anonymous))
    end

    def test_marshal_task
	peer2peer do |remote|
	    PeerServer.class_eval do
		def task
		    plan.add_mission(@task = Tasks::Simple.new_submodel.new(:id => 1))
		    @task.data = [42, @task.class]
		    [@task, @task.remote_id]
		end
		def check_sibling(remote_id)
		    @task.remote_siblings[peer] == remote_id
		end
	    end
	end

	remote_task, remote_task_id = remote_peer.call(:task)
	assert_kind_of(Task::DRoby, remote_task)
	assert_equal({:id => 1},    remote_task.arguments)
	assert_kind_of(Plan::DRoby, remote_task.plan)
	assert_equal("Roby::Test::Tasks::Simple",  remote_task.model.ancestors[1].first)
	assert_equal([42, remote_task.model], remote_task.data)
	Marshal.dump(remote_task)
	assert_equal(remote_task_id, remote_task.remote_siblings[remote_peer.droby_dump(nil)], remote_task.remote_siblings)
	assert(!remote_task.remote_siblings[Roby::Distributed.droby_dump(nil)])

	plan.add_permanent(local_proxy = remote_peer.local_object(remote_task))
	assert_kind_of(Tasks::Simple,  local_proxy)
	refute_same(Tasks::Simple, local_proxy.class)
	assert_equal([42, local_proxy.class], local_proxy.data)

	assert_equal([remote_peer],  local_proxy.owners)
	assert_equal(remote_task_id, local_proxy.remote_siblings[remote_peer])
	assert(!local_proxy.read_write?)
	assert( local_proxy.root_object?)
	assert(!local_proxy.event(:start).root_object?)
	remote_peer.synchro_point
	assert(remote_peer.call(:check_sibling, local_proxy.remote_id))
	assert(local_proxy.executable?)
        Roby.execute do
            assert_raises(OwnershipError) { local_proxy.start! }
        end
    end

    class ErrorWithArguments < Exception
	def initialize(a, b)
	end
    end

    def test_marshal_exception
	model = Class.new(Exception)
	e = model.exception("test")

	formatted = Distributed.format(e)
	assert_kind_of(Exception::DRoby, formatted)
	Marshal.dump(formatted)

	peer2peer do |remote|
	    def remote.exception
		model = Class.new(Exception)
		e = model.exception("test")
		Distributed.format(e)
	    end

	    def remote.exception_with_arguments
		e = begin
			raise ErrorWithArguments.new(1, 2), "test"
		    rescue ErrorWithArguments => e
			e
		    end

		Distributed.format(e)
	    end
	end

	m_e = remote.exception
	e   = remote_peer.local_object(m_e)
	assert_kind_of(Exception, e)
	refute_same(Exception, e.class)
	assert_equal("test", e.message)

	m_e = remote.exception_with_arguments
	e   = remote_peer.local_object(m_e)
	assert_kind_of(Exception, e)
	assert_same(Exception, e.class)
	assert_equal("test (TC_DistributedRobyProtocol::ErrorWithArguments)", e.message)
    end

    # See #test_local_task_back_forth_through_drb_race_condition
    # This test checks the case where we received the added_sibling message
    def test_local_task_back_forth_through_drb
	peer2peer do |remote|
	    PeerServer.class_eval do
		def proxy(object)
		    Marshal.dump(object)
		    plan.add_permanent(task = peer.local_object(object))
		    task
		end
	    end
	end

	plan.add_permanent(local_task = Tasks::Simple.new(:id => 'local'))
	remote_proxy = remote_peer.call(:proxy, local_task)
	remote_peer.synchro_point
	assert(remote_peer.proxies[remote_proxy], [remote_peer.proxies, remote_proxy])
	assert_same(local_task, remote_peer.local_object(remote_proxy), "#{local_task} #{remote_proxy}")
    end

    # This tests the handling of the following race condition:
    # * we send throught DRb a local object and gets back the marshalled
    #   proxy of our remote peer
    # * we get the local object which corresponds to the marshalled
    #   object, which should be the original local object
    #
    # The trick here is that, since we disable communication, we call
    # #local_object while the local host does not know yet that the remote host
    # has a sibling for the object
    def test_local_task_back_forth_through_drb_race_condition
	peer2peer do |remote|
	    def remote.proxy(object)
		Marshal.dump(object)
		plan.add_permanent(task = local_peer.local_object(object))
		task
	    end
	end

	begin
	    remote.disable_communication
	    plan.add_permanent(local_task = Tasks::Simple.new(:id => 'local'))
	    remote_proxy = remote.proxy(Distributed.format(local_task))
	    assert_equal(remote_proxy, remote.proxy(Distributed.format(local_task)))
	    assert(!remote_peer.proxies[remote_proxy])

	ensure
	    remote.enable_communication
	end

	# Test that it is fine to receive the #added_sibling message now
	remote_peer.synchro_point
    end

    class FinalizedRemoteTaskRaceTask < Tasks::Simple
        argument :newarg
    end

    # test a particular situations of GC/communication interaction
    # - A finalizes a task T which is owned by B
    # - A receives a message involving T which has been emitted while B was not knowing about the
    #   deletion (it has not yet received the removed_sibling message)
    def test_finalized_remote_task_race_condition
	peer2peer do |remote|
	    remote.plan.add_mission(task = FinalizedRemoteTaskRaceTask.new(:id => 'remote'))
	    
	    remote.singleton_class.class_eval do
		define_method(:send_task_update) do
		    task.arguments[:newarg] = 'tested'
		    Distributed.format(task)
		end
	    end
	end

	task = remote_task(:id => 'remote') do |task|
	    remote_peer.disable_tx
	    task
	end

	engine.wait_one_cycle
	assert(!task.plan)

	new_task = remote_peer.local_object(remote.send_task_update)
	refute_same(task, new_task)
	assert_equal('tested', new_task.arguments[:newarg])

    ensure
	remote_peer.enable_tx
    end

    def test_marshal_task_arguments
	peer2peer do |remote|
	    PeerServer.class_eval do
		def task
		    plan.add_mission(@task = model.new(:id => 1, :model => model))
		    @task
		end
		def model
		    @model ||= Tasks::Simple.new_submodel do
                        argument :model
                    end
		end
	    end
	end
	m_model = remote_peer.call(:model)
	m = m_model.proxy(remote_peer)

	m_task = remote_peer.call(:task)
	Marshal.dump(m_task)
	assert_equal(m_model.ancestors, m_task.arguments[:model].ancestors)
	assert_equal(m_model.tags, m_task.arguments[:model].tags)
	t = remote_peer.local_object(m_task)
	assert_equal({ :id => 1, :model => m }, t.arguments)
    end

    def test_marshal_task_event
	peer2peer do |remote|
	    PeerServer.class_eval do
		attr_reader :task
		def task_event
		    @task = Tasks::Simple.new_submodel.new(:id => 1)
		    task.event(:start)
		end
	    end
	end

	remote_event = remote_peer.call(:task_event)
	Marshal.dump(remote_event)
	assert_kind_of(TaskEventGenerator::DRoby, remote_event)
	task = remote_peer.call(:task)
	assert_equal(task.remote_siblings, remote_event.task.remote_siblings)
	assert_equal(remote_peer.local_object(task), remote_peer.local_object(remote_event.task))
    end

    CommonTaskModelTag = TaskService.new_submodel
    def test_marshal_task_model_tag
	peer2peer do |remote|
	    PeerServer.class_eval do
		def tag; CommonTaskModelTag end
		def anonymous_tag
		    @anonymous ||= TaskService.new_submodel do
			provides CommonTaskModelTag
		    end
		end
		def tagged_task_model
		    Tasks::Simple.new_submodel do
			provides CommonTaskModelTag
		    end
		end
		def anonymously_tagged_task_model
		    tag = anonymous_tag
		    Tasks::Simple.new_submodel do
			provides tag
		    end
		end
	    end
	end

	Marshal.dump(CommonTaskModelTag)
	assert_equal(CommonTaskModelTag, remote_peer.call(:tag).proxy(remote_peer))
	tagged_task_model = remote_peer.call(:tagged_task_model).proxy(remote_peer)
	assert(tagged_task_model.has_ancestor?(CommonTaskModelTag), tagged_task_model.ancestors)

	anonymous_tag = remote_peer.call(:anonymous_tag).proxy(remote_peer)
	refute_equal(CommonTaskModelTag, anonymous_tag)
	assert(anonymous_tag.has_ancestor?(CommonTaskModelTag), anonymous_tag.ancestors)
	assert_equal(anonymous_tag, remote_peer.call(:anonymous_tag).proxy(remote_peer))

	tagged_task_model = remote_peer.call(:anonymously_tagged_task_model).proxy(remote_peer)
	assert(tagged_task_model.has_ancestor?(CommonTaskModelTag))
	assert(tagged_task_model.has_ancestor?(anonymous_tag))
    end

    def test_marshal_event
	peer2peer do |remote|
	    remote.plan.add_mission(t = Task.new)
	    t.signals(:start, (ev = EventGenerator.new(true)))
	    t.event(:start).forward_to(ev = EventGenerator.new(false))
	    t.signals(:start, (ev = EventGenerator.new { }))
	    PeerServer.class_eval do
		include Minitest::Assertions
		define_method(:events) { plan.free_events }
	    end
	end
	
        marshalled = remote_peer.call(:events)
        marshalled.each { |ev| assert_kind_of(EventGenerator::DRoby, ev) }
        Roby.execute do
            all_events = marshalled.map { |ev| remote_peer.local_object(ev) }
            assert_equal(1, all_events.find_all { |ev| !ev.controlable? }.size)
            assert_equal(2, all_events.find_all { |ev| ev.controlable? }.size)
            all_events.each do |ev|
                if ev.controlable?
                    assert_raises(OwnershipError) { ev.call }
                end
                assert_raises(OwnershipError) { ev.emit }
            end
        end
    end

    def test_siblings
	peer2peer do |remote|
	    plan.add_mission(Roby::Task.new(:id => 'remote'))
	end

	plan.add_mission(remote_task = remote_task(:id => 'remote'))
	assert(remote_task.has_sibling_on?(remote_peer))
	remote_object, _ = remote_peer.proxies.find { |_, task| task == remote_task }
	assert(remote_object)
	assert_equal(remote_object, remote_task.sibling_on(remote_peer))

	assert_equal(remote_task, remote_task(:id => 'remote'))
	process_events
	assert_equal(remote_task, remote_task(:id => 'remote'))
    end


    def test_incremental_dump
	DRb.start_service
	FlexMock.use do |obj|
	    obj.should_receive(:droby_dump).and_return([]).once
	    FlexMock.use do |destination|
		destination.should_receive(:incremental_dump?).and_return(false).once
		assert_equal([], Distributed.format(obj, destination))
	    end

	    obj.should_receive(:remote_id).and_return(Distributed::RemoteID.from_object(obj)).once
	    FlexMock.use do |destination|
		destination.should_receive(:incremental_dump?).and_return(true).once
		assert_equal(Distributed::RemoteID.from_object(obj), Distributed.format(obj, destination))
	    end
	end
    end

    def test_local_object
	model = Roby::Task.new_submodel do
	    local_only
	end
	task = model.new
	assert(!task.distribute?)
    end

    def test_dump_sequence
	DRb.start_service
	t1, t2 = prepare_plan :add => 2
	p = t1+t2

	formatted = Distributed.format(p)
	Marshal.dump(formatted)
    end

    def test_dump_parallel
	DRb.start_service
	t1, t2 = prepare_plan :add => 2
	p = t1|t2

	formatted = Distributed.format(p)
	Marshal.dump(formatted)
    end
end

