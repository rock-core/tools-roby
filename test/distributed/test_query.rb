$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'

class TC_DistributedQuery < Test::Unit::TestCase
    include Roby::Distributed::Test
    def test_local
	t1 = Class.new(Task) do
	end.new

	t2 = Class.new(Task) do
	    def local?; false end
	end.new

	plan << t1 << t2
	assert_equal([t1].to_set, TaskMatcher.local.enum_for(:each, plan).to_set)
    end
    def test_ownership
	t1 = Class.new(Task) do
	end.new

	t2 = Class.new(Task) do
	    def owners; [Roby].to_set end # completely fake remote ID !
	end.new

	plan << t1 << t2
	assert_equal([t1].to_set, TaskMatcher.owned_by(Distributed.remote_id).enum_for(:each, plan).to_set)
	assert_equal([t1].to_set, TaskMatcher.self_owned.enum_for(:each, plan).to_set)
	assert_equal([t2].to_set, TaskMatcher.owned_by(Roby).enum_for(:each, plan).to_set)
	assert_equal([].to_set, TaskMatcher.owned_by(Roby::Distributed).enum_for(:each, plan).to_set)
    end

    # Check that we can query the remote plan database
    def test_query
	peer2peer do |remote|
	    local_model = Class.new(SimpleTask)

	    mission, subtask = Task.new(:id => 1), local_model.new(:id => 2)
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

	# Test queries
	result = remote_peer.find_tasks.to_a
	assert_equal(3, result.size)

	result = remote_peer.find_tasks.
	    with_arguments(:id => 1).to_a
	assert_equal(1, result.size)
	assert_equal(1, result[0].arguments[:id])

	result = remote_peer.find_tasks.
	    with_arguments(:id => 2).to_a
	assert_equal(1, result.size)
	assert(2, result[0].arguments[:id])

	result = (TaskMatcher.with_arguments(:id => 1) | TaskMatcher.with_arguments(:id => 2)).enum_for(:each, remote_peer).to_a
	assert_equal(2, result.size)

	result = (TaskMatcher.with_arguments(:id => 1) & TaskMatcher.with_model(SimpleTask)).enum_for(:each, remote_peer).to_a
	assert_equal(0, result.size)

	result = TaskMatcher.with_arguments(:id => 1).negate.enum_for(:each, remote_peer).to_a
	assert_equal(2, result.size, result)

	result = remote_peer.find_tasks.
	    with_model(Roby::Task).to_a
	assert_equal(3, result.size)

	result = remote_peer.find_tasks.
	    with_model(SimpleTask).to_a
	assert_equal(1, result.size)
	assert(2, result[0].arguments[:id])

	r_subtask = remote_peer.proxy(r_tasks.find { |t| t.arguments[:id] == 2 })
	result = remote_peer.find_tasks.
	    with_model(r_subtask.model).to_a
	assert_equal(1, result.size)
	assert(2, result[0].arguments[:id])
    end
end

