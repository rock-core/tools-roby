$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'

class TC_DistributedRobyProtocol < Test::Unit::TestCase
    include Roby::Distributed::Test

    TEST_ARRAY_SIZE = 7
    def dumpable_array
	task = Roby::Task.new(:id => 1)
	[1, task, 
	    Roby::EventGenerator.new {}, 
	    SimpleTask.new(:id => 2), 
	    task.event(:start), 
	    Roby::TaskStructure::Hierarchy, 
	    Class.new(Task).new(:id => 3) ]
    end
    def dumpable_hash
	Hash[*(0...TEST_ARRAY_SIZE).zip(dumpable_array).flatten]
    end
    def check_undumped_array(array)
	assert_equal(TEST_ARRAY_SIZE, array.size)
	assert_equal(1, array[0])

	assert_kind_of(MarshalledTask, array[1])
	assert_equal({:id => 1}, array[1].arguments)
	assert_equal(Roby::Task, array[1].model)

	assert_kind_of(MarshalledEventGenerator, array[2])
	assert(array[2].controlable)
	assert_equal(Roby::EventGenerator, array[2].model)

	assert_kind_of(MarshalledTask, array[3])
	assert_equal({:id => 2}, array[3].arguments)
	assert_equal(SimpleTask, array[3].model)

	assert_kind_of(MarshalledTaskEventGenerator, array[4])
	assert_equal(array[1], array[4].task)
	assert_equal(:start, array[4].symbol)

	assert_kind_of(Roby::RelationGraph, array[5])
	assert_equal(Roby::TaskStructure::Hierarchy.object_id, array[5].object_id)

	assert_kind_of(MarshalledTask, array[6])
	assert_not_equal(Task, array[6].model)
    end

    def test_enumerables
	test_case = self
	remote = remote_server do
	    define_method(:array)     { test_case.dumpable_array }
	    define_method(:value_set) { test_case.dumpable_array.to_value_set }
	    define_method(:_hash)     { test_case.dumpable_hash }
	    define_method(:array_of_array) { [test_case.dumpable_array] }
	end

	array = remote.array
	assert_kind_of(Array, array)
	check_undumped_array(array)

	hash = remote._hash
	assert_kind_of(Hash, hash)
	check_undumped_array(hash)

	array_of_array = remote.array_of_array
	assert_kind_of(Array, array_of_array)
	check_undumped_array(array_of_array[0])

	set = remote.value_set
	assert_kind_of(ValueSet, set)
	assert_equal(TEST_ARRAY_SIZE, set.size)
	assert(set.find { |o| o == 1 })
	assert(set.find { |t| t.kind_of?(MarshalledTask) && t.arguments[:id] == 1 })
	assert(set.find { |e| e.kind_of?(MarshalledEventGenerator) })
	assert(set.find { |t| t.kind_of?(MarshalledTask) && t.arguments[:id] == 2 })
    end

    def test_marshal_model
	peer2peer do |remote|
	    def remote.model
		SimpleTask
	    end
	    def remote.anonymous_model
		@anonymous ||= Class.new(model)
	    end
	    def remote.check_anonymous_model(remote)
		@anonymous == remote
	    end
	end

	assert_equal(SimpleTask, remote.model)
	anonymous = remote.anonymous_model
	assert_not_equal(anonymous, SimpleTask)
	assert(anonymous < SimpleTask)
	assert(remote.check_anonymous_model(anonymous))
    end

    def test_marshal_task
	peer2peer do |remote|
	    def remote.task
	        task = Class.new(SimpleTask).new(:id => 1)
	        task.plan = Plan.new
	        task
	    end
	    def remote.proxy(object)
	        peer = peers.to_a[0][1]
	        peer.proxy(object)
	    end
	end

	local_task = Task.new
	remote_proxy = Marshal.load(Distributed.dump(local_task))
	assert_same(local_task, remote_proxy.remote_object)
	remote_proxy = Marshal.load(Distributed.dump(remote_proxy))
	assert_same(local_task, remote_proxy.remote_object)

	remote_task = remote.task
	assert_kind_of(MarshalledTask, remote_task)
	assert_equal({:id => 1}, remote_task.arguments)
	assert_kind_of(Plan::DRoby, remote_task.plan)
	assert_equal(SimpleTask, remote_task.model.ancestors[1])

	remote_proxy = remote.proxy(local_task)
	assert_kind_of(MarshalledTask, remote_proxy)
	assert_equal(local_task, remote_proxy.remote_object)
	assert_equal(local_task, remote_peer.proxy(remote_proxy))
    end

    def assert_marshalled_ancestors(expected, marshalled)
	assert_equal(expected, marshalled.model.ancestors.find_all { |klass| klass.instance_of?(Class) }[0, expected.size])
    end
    def test_marshal_task_event
	DRb.start_service
	remote = remote_server do
	    attr_reader :task
	    def task_event
		@task = Class.new(SimpleTask).new(:id => 1)
		task.event(:start)
	    end
	end

	local_event = Task.new.event(:start)
	assert_same(local_event, Marshal.load(Distributed.dump(local_event)).remote_object)

	remote_event = remote.task_event
	assert_kind_of(MarshalledTaskEventGenerator, remote_event)
	assert_equal(remote.task, remote_event.task)
	assert_marshalled_ancestors([TaskEventGenerator, EventGenerator], remote_event)
    end

    CommonTaskModelTag = TaskModelTag.new
    def test_marshal_task_model_tag
	peer2peer do |remote|
	    def remote.tag; CommonTaskModelTag end
	    def remote.anonymous_tag
		@anonymous ||= TaskModelTag.new do
		    include CommonTaskModelTag
		end
	    end
	    def remote.tagged_task_model
		Class.new(SimpleTask) do
		    include CommonTaskModelTag
		end
	    end
	    def remote.anonymously_tagged_task_model
		tag = anonymous_tag
		Class.new(SimpleTask) do
		    include tag
		end
	    end
	end

	Marshal.dump(CommonTaskModelTag)
	assert_equal(CommonTaskModelTag, remote.tag)
	tagged_task_model = remote.tagged_task_model
	assert(tagged_task_model.has_ancestor?(CommonTaskModelTag), tagged_task_model.ancestors)

	anonymous_tag = remote.anonymous_tag
	assert_not_equal(CommonTaskModelTag, anonymous_tag)
	assert(anonymous_tag.has_ancestor?(CommonTaskModelTag), anonymous_tag.ancestors)
	assert_equal(anonymous_tag, remote.anonymous_tag)

	tagged_task_model = remote.anonymously_tagged_task_model
	assert(tagged_task_model.has_ancestor?(CommonTaskModelTag))
	assert(tagged_task_model.has_ancestor?(anonymous_tag))
    end
end

