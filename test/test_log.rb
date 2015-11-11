require 'roby/test/distributed'

class TC_Log < Minitest::Test
    def teardown
	super
	Log.clear_loggers
    end

    def test_start_stop_logger
	FlexMock.use do |mock|
	    mock.should_receive(:close).once
	    Log.add_logger mock
	    assert(Log.logging?)
	    Log.start_logging

	    Log.remove_logger mock
	    assert(!Log.logging?)
	    Log.stop_logging
	end
    end

    def test_misc
	FlexMock.use do |mock|
            mock.should_receive(:logs_message?).with(:flush).and_return(false)
            mock.should_receive(:logs_message?).with(:event).and_return(true)
	    mock.should_receive(:splat?).and_return(true)
	    mock.should_receive(:event).with(1, 2)
	    mock.should_receive(:flush)
	    mock.should_receive(:close).once
	    Log.add_logger mock

	    assert(!Log.has_logger?(:flush))
	    assert(Log.has_logger?(:event))

	    assert_equal([mock], Log.enum_for(:each_logger, :event).to_a)
	    assert_equal([], Log.enum_for(:each_logger, :bla).to_a)
            Log.remove_logger mock
	end
    end

    def test_message_splat
	FlexMock.use do |mock|
            mock.should_receive(:logs_message?).and_return(true)
	    mock.should_receive(:splat?).and_return(true).twice
	    mock.should_receive(:splat_event).with(FlexMock.any, 1, 2).once
	    mock.should_receive(:flush).once
	    mock.should_receive(:close).once
	    Log.add_logger mock

	    Log.log(:splat_event) { [1, 2] }
            Log.remove_logger mock
	end
    end

    def test_message_nonsplat
	FlexMock.use do |mock|
            mock.should_receive(:logs_message?).and_return(true)
	    mock.should_receive(:splat?).and_return(false).twice
	    mock.should_receive(:nonsplat_event).with(FlexMock.any, [1, 2]).once
	    mock.should_receive(:flush).once
	    mock.should_receive(:close).once
	    Log.add_logger mock

	    Log.log(:nonsplat_event) { [1, 2] }
            Log.remove_logger mock
	end
    end

    def on_marshalled_task(task)
	FlexMock.on do |obj| 
	    obj.remote_siblings[Roby::Distributed.droby_dump(nil)] == task.remote_id
	end
    end
    def test_known_objects_management
	t1, t2 = Tasks::Simple.new, Tasks::Simple.new
	FlexMock.use do |mock|
            mock.should_receive(:logs_message?).and_return(true)
	    mock.should_receive(:splat?).and_return(true)
	    mock.should_receive(:added_task_child).
		with(FlexMock.any, on_marshalled_task(t1), [TaskStructure::Dependency].droby_dump(nil), 
		     on_marshalled_task(t2), FlexMock.any).once

	    match_discovered_set = FlexMock.on do |task_set| 
		task_set.map { |obj| obj.remote_siblings[Roby::Distributed.droby_dump(nil)] }.to_set == [t1.remote_id, t2.remote_id].to_set
	    end

	    mock.should_receive(:added_tasks).
		with(FlexMock.any, FlexMock.any, match_discovered_set).
		once
	    mock.should_receive(:removed_task_child).
		with(FlexMock.any, t1.remote_id, [TaskStructure::Dependency].droby_dump(nil), t2.remote_id).
		once
	    mock.should_receive(:finalized_task).
		with(FlexMock.any, FlexMock.any, t1.remote_id).
		once
            mock.should_receive(:close).once

	    Log.add_logger mock
	    begin
		t1.depends_on t2
		assert(Log.known_objects.empty?)
		plan.add(t1)
		assert_equal([t1, t2].to_value_set, Log.known_objects)
		t1.remove_child t2
		assert_equal([t1, t2].to_value_set, Log.known_objects)
		plan.remove_object(t1)
		assert_equal([t2].to_value_set, Log.known_objects)

		Log.flush
	    ensure
		Log.remove_logger mock
	    end
	end
    end
end

