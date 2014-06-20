require 'roby/test/distributed'
require 'roby/tasks/simple'

class TC_DistributedQuery < Minitest::Test
    def test_ownership
	DRb.start_service
	FlexMock.use do |fake_peer|
	    fake_peer.should_receive(:remote_name).and_return('fake_peer')
	    fake_peer.should_receive(:subscribed_plan?).and_return(false)
	    fake_peer.should_receive(:subscribed?).and_return(false)

	    t1 = Task.new_submodel.new
	    t2 = Task.new_submodel.new
	    t2.owners << fake_peer
	    plan.add [t1, t2]

	    assert_equal([t1].to_set, TaskMatcher.owned_by(Distributed).enum_for(:each, plan).to_set)
	    assert_equal([t1].to_set, TaskMatcher.self_owned.enum_for(:each, plan).to_set)
	    assert_equal([t2].to_set, TaskMatcher.owned_by(fake_peer, Distributed).enum_for(:each, plan).to_set, plan.task_index.by_owner)
	    assert_equal([].to_set, TaskMatcher.owned_by(fake_peer).enum_for(:each, plan).to_set, plan.task_index.by_owner)
	end
    end

    def test_marshal_query
	peer2peer do |remote|
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

    class QueryTaskModel < Roby::Task
        argument :id
    end

    # Check that we can query the remote plan database
    def test_query
	peer2peer do |remote|
	    local_model = Tasks::Simple.new_submodel

	    mission, subtask = QueryTaskModel.new(:id => 1), local_model.new(:id => 2)
	    mission.depends_on subtask
	    remote.plan.add_mission(mission)
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

	result = (TaskMatcher.with_arguments(:id => 1) & TaskMatcher.with_model(Tasks::Simple)).enum_for(:each, remote_peer).to_a
	assert_equal(0, result.size)

	result = TaskMatcher.with_arguments(:id => 1).negate.enum_for(:each, remote_peer).to_a
	assert_equal(1, result.size, result)

	result = remote_peer.find_tasks.
	    with_model(Roby::Task).to_a
	assert_equal(2, result.size)

	result = remote_peer.find_tasks.
	    with_model(Tasks::Simple).to_a
	assert_equal(1, result.size)
	assert(2, result[0].arguments[:id])

	r_subtask = *remote_peer.find_tasks.
	    with_arguments(:id => 2).to_a
	result = remote_peer.find_tasks.
	    with_model(r_subtask.model).to_a
	assert_equal(1, result.size)
	assert(2, result[0].arguments[:id])

	assert_equal([], remote_peer.find_tasks.
	    self_owned.to_a)
	assert_equal(2, remote_peer.find_tasks.
	    owned_by(remote_peer).to_a.size)
    end
end

