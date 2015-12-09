require 'roby/test/self'

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
	    obj.remote_id == task.remote_id
	end
    end

    def exercise_logger(logger_mock)
        Log.add_logger logger_mock
        begin
            yield
            Log.flush
        ensure
            Log.remove_logger logger_mock
        end
    end

    def test_logging_of_event_propagation_if_source_command_calls_target_command
        target = EventGenerator.new(true)
        source = EventGenerator.new { target.call("context") }

        logger_mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)
	    r.should_receive(:merged_plan)
            r.should_receive(:generator_calling).once.
                with(any, source.remote_id, Set[], "")
            r.should_receive(:generator_called).once.
                with(any, source.remote_id, "")
            r.should_receive(:generator_calling).once.
                with(any, target.remote_id, Set[source.remote_id], "[context]")
            r.should_receive(:generator_called).once.
                with(any, target.remote_id, "[context]")
            r.should_receive(:generator_emitting).once.
                with(any, target.remote_id, [target.remote_id], "[context]")
            r.should_receive(:generator_fired).once.
                with(any, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:close)
        end

        exercise_logger(logger_mock) do
            plan.add([source, target])
            source.call
        end
    end

    def test_logging_of_event_signalling_by_event_handlers
        target = EventGenerator.new(true)
        source = EventGenerator.new
        source.on { target.call("context") }

        logger_mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)
	    r.should_receive(:merged_plan)
            r.should_receive(:generator_emitting).once.
                with(any, source.remote_id, [], "")
            r.should_receive(:generator_fired).once.
                with(any, source.remote_id, Numeric, Time, "")
            r.should_receive(:generator_propagate_event).once.
                with(any, false, source.remote_id, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:generator_calling).once.
                with(any, target.remote_id, Set[source.remote_id], "[context]")
            r.should_receive(:generator_called).once.
                with(any, target.remote_id, "[context]")
            r.should_receive(:generator_emitting).once.
                with(any, target.remote_id, [target.remote_id], "[context]")
            r.should_receive(:generator_fired).once.
                with(any, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:close)
        end

        exercise_logger(logger_mock) do
            plan.add([source, target])
            source.emit
        end
    end

    def test_logging_of_event_propagation_if_source_command_emits_target_event
        target = EventGenerator.new
        source = EventGenerator.new { target.emit("context") }

        logger_mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)
	    r.should_receive(:merged_plan)
            r.should_receive(:generator_calling).once.
                with(any, source.remote_id, Set[], "")
            r.should_receive(:generator_called).once.
                with(any, source.remote_id, "")
            r.should_receive(:generator_emitting).once.
                with(any, target.remote_id, [source.remote_id], "[context]")
            r.should_receive(:generator_fired).once.
                with(any, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:close)
        end

        exercise_logger(logger_mock) do
            plan.add([source, target])
            source.call
        end
    end

    def test_logging_of_event_forwarding_by_event_handlers
        target = EventGenerator.new
        source = EventGenerator.new
        source.on { target.emit("context") }

        logger_mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)
	    r.should_receive(:merged_plan)
            r.should_receive(:generator_emitting).once.
                with(any, source.remote_id, [], "")
            r.should_receive(:generator_fired).once.
                with(any, source.remote_id, Numeric, Time, "")
            r.should_receive(:generator_propagate_event).once.
                with(any, true, source.remote_id, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:generator_emitting).once.
                with(any, target.remote_id, [source.remote_id], "[context]")
            r.should_receive(:generator_fired).once.
                with(any, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:close)
        end

        exercise_logger(logger_mock) do
            plan.add([source, target])
            source.emit
        end
    end

    def test_logging_of_event_signalling_by_relation
        target = EventGenerator.new(true)
        source = EventGenerator.new
        source.signals target

        logger_mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)
	    r.should_receive(:merged_plan)
            r.should_receive(:generator_emitting).once.
                with(any, source.remote_id, [], "[context]")
            r.should_receive(:generator_fired).once.
                with(any, source.remote_id, Numeric, Time, "[context]")
            r.should_receive(:generator_propagate_event).once.
                with(any, false, source.remote_id, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:generator_calling).once.
                with(any, target.remote_id, Set[source.remote_id], "[context]")
            r.should_receive(:generator_called).once.
                with(any, target.remote_id, "[context]")
            r.should_receive(:generator_emitting).once.
                with(any, target.remote_id, [target.remote_id], "[context]")
            r.should_receive(:generator_fired).once.
                with(any, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:close)
        end

        exercise_logger(logger_mock) do
            plan.add([source, target])
            source.emit("context")
        end
    end

    def test_logging_of_event_forwarding_by_relation
        target = EventGenerator.new
        source = EventGenerator.new
        source.forward_to target

        logger_mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)
	    r.should_receive(:merged_plan)
            r.should_receive(:generator_emitting).once.
                with(any, source.remote_id, [], "[context]")
            r.should_receive(:generator_fired).once.
                with(any, source.remote_id, Numeric, Time, "[context]")
            r.should_receive(:generator_propagate_event).once.
                with(any, true, source.remote_id, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:generator_emitting).once.
                with(any, target.remote_id, [source.remote_id], "[context]")
            r.should_receive(:generator_fired).once.
                with(any, target.remote_id, Numeric, Time, "[context]")
            r.should_receive(:close)
        end

        exercise_logger(logger_mock) do
            plan.add([source, target])
            source.emit("context")
        end
    end

    def test_logging_of_task_lifecycle
	t1, t2 = Tasks::Simple.new, Tasks::Simple.new

        mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)

	    r.should_receive(:merged_plan).
                with(FlexMock.any, FlexMock.any, on { |plan| plan.known_tasks.keys.map(&:remote_id) == [t1.remote_id] }).
                once.pass_thru.ordered
	    r.should_receive(:merged_plan).
                with(FlexMock.any, FlexMock.any, on { |plan| plan.known_tasks.keys.map(&:remote_id) == [t2.remote_id] }).
                once.pass_thru.ordered
	    r.should_receive(:added_edge).
                with(FlexMock.any, t1.remote_id, t2.remote_id, [TaskStructure::Dependency].droby_dump(nil), 
                     FlexMock.any).once.ordered
	    r.should_receive(:removed_edge).
                with(FlexMock.any, t1.remote_id, t2.remote_id, [TaskStructure::Dependency].droby_dump(nil)).
                once.ordered
	    r.should_receive(:finalized_task).
		with(FlexMock.any, t1.remote_id).
                once.ordered
            r.should_receive(:close).once
        end

        Log.add_logger mock
        begin
            plan.add(t1)
            assert_equal([t1].to_set, Log.known_objects)
            t1.depends_on t2
            assert_equal([t1, t2].to_set, Log.known_objects)
            t1.remove_child t2
            assert_equal([t1, t2].to_set, Log.known_objects)
            plan.remove_object(t1)
            assert_equal([t2].to_set, Log.known_objects)

            Log.flush
        ensure
            Log.remove_logger mock
        end
    end

    def test_removing_task_does_not_remove_emit_relation_removal
	t1, t2 = Tasks::Simple.new, Tasks::Simple.new

        mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)

	    r.should_receive(:merged_plan).
                with(FlexMock.any, FlexMock.any, on { |plan| plan.known_tasks.keys.map(&:remote_id) == [t1.remote_id] }).
                once.pass_thru.ordered
	    r.should_receive(:merged_plan).
                with(FlexMock.any, FlexMock.any, on { |plan| plan.known_tasks.keys.map(&:remote_id) == [t2.remote_id] }).
                once.pass_thru.ordered
	    r.should_receive(:added_edge).
                with(FlexMock.any, t1.remote_id, t2.remote_id, [TaskStructure::Dependency].droby_dump(nil), 
                     FlexMock.any).once.ordered
	    r.should_receive(:finalized_task).
		with(FlexMock.any, t1.remote_id).
                once.ordered
            r.should_receive(:close).once
        end

        Log.add_logger mock
        begin
            plan.add(t1)
            assert_equal([t1].to_set, Log.known_objects)
            t1.depends_on t2
            assert_equal([t1, t2].to_set, Log.known_objects)
            plan.remove_object(t1)
            assert_equal([t2].to_set, Log.known_objects)

            Log.flush
        ensure
            Log.remove_logger mock
        end
    end

    def test_logging_of_event_lifecycle
	e1, e2 = EventGenerator.new, EventGenerator.new

        relations = [
            EventStructure::Forwarding,
            EventStructure::CausalLink,
            EventStructure::Precedence]
        logger_mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)

	    r.should_receive(:merged_plan).
                with(FlexMock.any, FlexMock.any, on { |plan| plan.free_events.keys.map(&:remote_id) == [e1.remote_id] }).
                once.pass_thru.ordered
	    r.should_receive(:merged_plan).
                with(FlexMock.any, FlexMock.any, on { |plan| plan.free_events.keys.map(&:remote_id) == [e2.remote_id] }).
                once.pass_thru.ordered
	    r.should_receive(:added_edge).
                with(FlexMock.any, e1.remote_id, e2.remote_id, relations.droby_dump(nil), 
                     FlexMock.any).once.ordered
	    r.should_receive(:removed_edge).
                with(FlexMock.any, e1.remote_id, e2.remote_id, relations.droby_dump(nil)).
                once.ordered
	    r.should_receive(:finalized_event).
		with(FlexMock.any, e1.remote_id).
                once.ordered
            r.should_receive(:close).once
        end

        Log.add_logger logger_mock
        begin
            plan.add(e1)
            assert_equal([e1].to_set, Log.known_objects)
            e1.forward_to e2
            assert_equal([e1, e2].to_set, Log.known_objects)
            e1.remove_forwarding e2
            assert_equal([e1, e2].to_set, Log.known_objects)
            plan.remove_object(e1)
            assert_equal([e2].to_set, Log.known_objects)

            Log.flush
        ensure
            Log.remove_logger logger_mock
        end
    end

    def test_removing_event_does_not_emit_relation_removal
	e1, e2 = EventGenerator.new, EventGenerator.new

        relations = [
            EventStructure::Forwarding,
            EventStructure::CausalLink,
            EventStructure::Precedence]
        logger_mock = flexmock do |r|
            r.should_receive(:logs_message?).and_return(true)
	    r.should_receive(:splat?).and_return(true)

	    r.should_receive(:merged_plan).
                with(FlexMock.any, FlexMock.any, on { |plan| plan.free_events.keys.map(&:remote_id) == [e1.remote_id] }).
                once.pass_thru.ordered
	    r.should_receive(:merged_plan).
                with(FlexMock.any, FlexMock.any, on { |plan| plan.free_events.keys.map(&:remote_id) == [e2.remote_id] }).
                once.pass_thru.ordered
	    r.should_receive(:added_edge).
                with(FlexMock.any, e1.remote_id, e2.remote_id, relations.droby_dump(nil), 
                     FlexMock.any).once.ordered
	    r.should_receive(:finalized_event).
		with(FlexMock.any, e1.remote_id).
                once.ordered
            r.should_receive(:close).once
        end

        Log.add_logger logger_mock
        begin
            plan.add(e1)
            assert_equal([e1].to_set, Log.known_objects)
            e1.forward_to e2
            assert_equal([e1, e2].to_set, Log.known_objects)
            plan.remove_object(e1)
            assert_equal([e2].to_set, Log.known_objects)

            Log.flush
        ensure
            Log.remove_logger logger_mock
        end
    end

end

