$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'test_config'
require 'mockups/tasks'
require 'roby/distributed/connection_space'
require 'roby/distributed/proxy'

class TC_DistributedRobyProtocol < Test::Unit::TestCase
    include Roby::Distributed
    include RobyTestCommon

    TEST_ARRAY_SIZE = 6
    def dumpable_array
	task = Roby::Task.new(:id => 1)
	[1, task, Roby::EventGenerator.new {}, SimpleTask.new(:id => 2), task.event(:start), Roby::TaskStructure::Hierarchy]
    end
    def dumpable_hash
	Hash[*(0...TEST_ARRAY_SIZE).zip(dumpable_array).flatten]
    end
    def check_undumped_array(array)
	assert_equal(TEST_ARRAY_SIZE, array.size)
	assert_equal(1, array[0])

	assert_kind_of(MarshalledTask, array[1])
	assert_equal({:id => 1}, array[1].arguments)
	assert_equal([Roby::Task], array[1].ancestors)

	assert_kind_of(MarshalledEventGenerator, array[2])
	assert(array[2].controlable)
	assert_equal([Roby::EventGenerator], array[2].ancestors)

	assert_kind_of(MarshalledTask, array[3])
	assert_equal({:id => 2}, array[3].arguments)
	assert_equal([SimpleTask, ExecutableTask, Roby::Task], array[3].ancestors)

	assert_kind_of(MarshalledTaskEventGenerator, array[4])
	assert_equal(array[1], array[4].task)
	assert_equal(:start, array[4].symbol)

	assert_kind_of(Roby::RelationGraph, array[5])
	assert_equal(Roby::TaskStructure::Hierarchy.object_id, array[5].object_id)
    end

    def test_enumerables
	test_case = self
	remote_process do
	    server = Class.new do
		define_method(:array)     { test_case.dumpable_array }
		define_method(:value_set) { test_case.dumpable_array.to_value_set }
		define_method(:_hash)     { test_case.dumpable_hash }
		define_method(:array_of_array) { [test_case.dumpable_array] }
	    end.new
	    DRb.start_service 'roby://localhost:1245', server
	end
	DRb.start_service 'roby://localhost:1246'
	remote = DRbObject.new_with_uri('roby://localhost:1245')

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
end


