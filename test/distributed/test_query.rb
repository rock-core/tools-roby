$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'test/mockups/tasks'
require 'flexmock'

class TC_DistributedQuery < Test::Unit::TestCase
    include Roby::Distributed::Test

    def test_ownership
	DRb.start_service
	FlexMock.use do |fake_peer|
	    fake_peer.should_receive(:remote_name).and_return('fake_peer')
	    fake_peer.should_receive(:subscribed_plan?).and_return(false)
	    fake_peer.should_receive(:subscribed?).and_return(false)

	    t1 = Class.new(Task).new
	    t2 = Class.new(Task).new
	    plan << t1 << t2

	    t2.owners.clear
	    t2.owners << fake_peer

	    assert_equal([t1].to_set, TaskMatcher.owned_by(Distributed).enum_for(:each, plan).to_set)
	    assert_equal([t1].to_set, TaskMatcher.self_owned.enum_for(:each, plan).to_set)
	    assert_equal([t2].to_set, TaskMatcher.owned_by(fake_peer).enum_for(:each, plan).to_set)
	end
    end

    def test_marshal_query
	peer2peer(true) do |remote|
	    PeerServer.class_eval do
		def query
		    plan.find_tasks
		end
	    end
	end

	m_query = remote_peer.call(:query)
	assert_kind_of(Query::DRoby, m_query)
	query = remote_peer.local_object(m_query)
	assert_kind_of(Query, query)
    end

    # Check that we can query the remote plan database
    def test_query
	peer2peer(true) do |remote|
	    local_model = Class.new(SimpleTask)

	    mission, subtask = Task.new(:id => 1), local_model.new(:id => 2)
	    mission.realized_by subtask
	    remote.plan.insert(mission)
	end

	# Get the remote missions
	r_missions = remote_peer.find_tasks.mission.to_a
	assert(r_missions.find { |t| t.arguments[:id] == 1 }, r_missions)

	# Test queries
	result = remote_peer.find_tasks.to_a
	assert_equal(2, result.size)

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
	assert_equal(1, result.size, result)

	result = remote_peer.find_tasks.
	    with_model(Roby::Task).to_a
	assert_equal(2, result.size)

	result = remote_peer.find_tasks.
	    with_model(SimpleTask).to_a
	assert_equal(1, result.size)
	assert(2, result[0].arguments[:id])

	r_subtask = *remote_peer.find_tasks.
	    with_arguments(:id => 2).to_a
	result = remote_peer.find_tasks.
	    with_model(r_subtask.model).to_a
	assert_equal(1, result.size)
	assert(2, result[0].arguments[:id])
    end
end

