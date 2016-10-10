module Roby
    module Test
        module Assertions
            # Capture log output and returns it
            def capture_log(object, level)
                Roby.disable_colors

                capture = Array.new
                if object.respond_to?(:logger)
                    object = object.logger
                end

                original_level = object.level
                level_value = Logger.const_get(level.upcase)
                if original_level > level_value
                    object.level = level_value
                end

                FlexMock.use(object) do |mock|
                    mock.should_receive(level).
                        and_return do |msg|
                            if msg.respond_to?(:to_str)
                                capture << msg
                            else
                                mock.invoke_original(level) do
                                    capture << msg.call
                                    break
                                end
                            end
                        end

                    yield
                end
                capture
            ensure
                Roby.enable_colors_if_available
                object.level = original_level
            end

            # Asserts that a block will add a LocalizedError to be processed
            #
            # @param [#match,Queries::LocalizedErrorMatcher] an error matcher
            def assert_adds_roby_localized_error(matcher)
                matcher = matcher.match.to_execution_exception_matcher
                errors = plan.execution_engine.gather_errors do
                    yield
                end

                refute errors.empty?, "expected to have added a LocalizedError, but got none"
                errors.each do |e|
                    assert_exception_can_be_pretty_printed(e.exception)
                end
                if matched_e = errors.find { |e| matcher === e }
                    return matched_e.exception
                elsif errors.empty?
                    flunk "block was expected to add an error matching #{matcher}, but did not"
                else
                    raise SynchronousEventProcessingMultipleErrors.new(errors.map(&:exception))
                end
            end

            # Verifies that the given exception object does not raise when
            # pretty-printed
            def assert_exception_can_be_pretty_printed(e)
                PP.pp(e, "") # verify that the exception can be pretty-printed, all Roby exceptions should
            end

            # Asserts the type of the exception that caused a localized error
            def assert_original_error(klass, localized_error_type = LocalizedError)
                old_level = Roby.logger.level
                Roby.logger.level = Logger::FATAL

                begin
                    yield
                rescue Exception => e
                    assert_kind_of(localized_error_type, e)
                    assert_respond_to(e, :error)
                    assert_kind_of(klass, e.error)
                end
            ensure
                Roby.logger.level = old_level
            end

            # Exception raised in the block of assert_doesnt_timeout when the timeout
            # is reached
            class FailedTimeout < RuntimeError; end

            # Checks that the given block returns within +seconds+ seconds
            def assert_doesnt_timeout(seconds, message = "watchdog #{seconds} failed")
                watched_thread = Thread.current
                watchdog = Thread.new do
                    sleep(seconds)
                    watched_thread.raise FailedTimeout
                end

                assert_block(message) do
                    begin
                        yield
                        true
                    rescue FailedTimeout
                    ensure
                        watchdog.kill
                        watchdog.join
                    end
                end
            end

            # Checks that the given block raises FailedTimeout
            def assert_times_out(&block)
                assert_raises(Timeout::Error, &block)
            end

	    # Wait for events to be emitted, or for some events to not be
            # emitted
            #
            # It will fail if all waited-for events become unreachable
            #
            # If a block is given, it is called after the checks are put in
            # place. This is required if the code in the block causes the
            # positive/negative events to be emitted
	    #
	    # @example test a task failure
	    #	assert_event_emission(task.fail_event) do
	    #	    task.start!
	    #	end
            #
            # @param [Array<EventGenerator>] positive the set of events whose
            #   emission we are waiting for
            # @param [Array<EventGenerator>] negative the set of events whose
            #   emission will cause the assertion to fail
            # @param [String] msg assertion failure message
            # @param [Float] timeout timeout in seconds after which the
            #   assertion fails if none of the positive events got emitted
            def assert_event_emission(positive = [], negative = [], msg = nil, timeout = 5, scheduler: nil, garbage_collect_pass: true, &block)
                old_scheduler = plan.execution_engine.scheduler.enabled?
                if !scheduler.nil?
                    plan.execution_engine.scheduler.enabled = scheduler
                end

                ivar, unreachability_reason = watch_events(positive, negative, timeout, garbage_collect_pass: garbage_collect_pass, &block)

                if !ivar.fulfilled?
                    if !unreachability_reason.empty?
                        msg = format_unreachability_message(unreachability_reason)
                        flunk("all positive events are unreachable for the following reason:\n  #{msg}")
                    elsif msg
                        flunk("#{msg} failed: #{ivar.reason}")
                    else
                        flunk(ivar.reason)
                    end
                end

            ensure
                plan.execution_engine.scheduler.enabled = old_scheduler
            end

            def watch_events(positive, negative, timeout, garbage_collect_pass: true, &block)
                if execution_engine.running?
                    raise NotImplementedError, "using running engines in tests is not supported anymore"
                end

                positive = Array[*(positive || [])].to_set
                negative = Array[*(negative || [])].to_set
                if positive.empty? && negative.empty? && !block
                    raise ArgumentError, "neither a block nor a set of positive or negative events have been given"
                end

                unreachability_reason = Set.new
                positive.each do |ev|
                    ev.if_unreachable(cancel_at_emission: true) do |reason, event|
                        unreachability_reason << [event, reason]
                    end
                end

                if positive.empty? && negative.empty?
                    positive, negative = yield
                    positive = Array[*(positive || [])].to_set
                    negative = Array[*(negative || [])].to_set
                    if positive.empty? && negative.empty?
                        raise ArgumentError, "#{block} returned no events to watch"
                    end
                elsif block_given?
                    yield
                end

                success, error = Assertions.event_watch_result(positive, negative)

                ivar = Concurrent::IVar.new
                if success
                    ivar.set(success)
                elsif error
                    ivar.fail(error)
                else
                    @watched_events = [ivar, positive, negative, Time.now + timeout]
                end

                begin
                    while !ivar.complete?
                        process_events(garbage_collect_pass: garbage_collect_pass)
                    end
                ensure
                    @watched_events = nil
                end
                return ivar, unreachability_reason
            end

            def format_unreachability_message(unreachability_reason)
                msg = unreachability_reason.map do |ev, reason|
                    if reason.kind_of?(Exception)
                        Roby.format_exception(reason).join("\n")
                    elsif reason.respond_to?(:context)
                        context = if reason.context
                                      Roby.format_exception(reason.context).join("\n")
                                  end
                        "the emission of #{reason}#{context}"
                    elsif !reason
                        "unknown"
                    else
                        reason.to_s
                    end
                end
                msg.join("\n  ")
            end

            # Asserts that the given task is going to be added to the quarantine
            def assert_task_quarantined(task, timeout: 5)
                yield
                while !task.plan.quarantined_task?(task) && (Time.now - start) < timeout
                    task.plan.execution_engine.process_events
                end
            end

            # @deprecated use #assert_event_emission instead
	    def assert_any_event(positive = [], negative = [], msg = nil, timeout = 5, &block)
                Roby.warn_deprecated "#assert_any_event is deprecated, use #assert_event_emission instead"
                assert_event_emission(positive, negative, msg, timeout, &block)
	    end

            # @deprecated use #assert_event_becomes_unreachable instead
            def assert_becomes_unreachable(*args, &block)
                Roby.warn_deprecated "#assert_becomes_unreachable is deprecated, use #assert_event_becomes_unreachable instead"
                assert_event_becomes_unreachable(*args, &block)
            end

            # Verifies that the provided event becomes unreachable within a
            # certain time frame
            #
            # @param [EventGenerator] event
            # @param [Float] timeout in seconds
            # @yield a block of code that performs the action that should turn
            #   the event into unreachable
            def assert_event_becomes_unreachable(event, timeout = 5, &block)
                old_level = Roby.logger.level
                Roby.logger.level = Logger::FATAL
                ivar, unreachability_reason = watch_events(event, [], timeout, &block)
                if reason = unreachability_reason.find { |ev, _| ev == event }
                    return reason.last
                end
                if ivar.fulfilled?
                    flunk("event has been emitted")
                else
                    msg = if !unreachability_reason.empty?
                              format_unreachability_message(unreachability_reason)
                          else
                              ivar.reason
                          end
                    flunk("the following error happened before #{event} became unreachable:\n #{msg}")
                end
            ensure
                Roby.logger.level = old_level
            end

            # Verifies that a given event is unreachable, optionally checking
            # its unreachability reason
            #
            # @return the unreachability reason
            def assert_event_is_unreachable(event, reason: nil)
                assert event.unreachable?, "#{event} was expected to be unreachable but is not"
                if reason
                    assert(reason === event.unreachability_reason, "the unreachability of #{event} was expected to match #{reason} but it is #{event.unreachability_reason}")
                end
                event.unreachability_reason
            end

            def assert_child_of(parent, child, relation, *info)
                assert_same parent.relation_graphs, child.relation_graphs, "#{parent} and #{child} cannot be related as they are not acting on the same relation graphs"
                graph = parent.relation_graph_for(relation)
                assert graph.has_vertex?(parent), "#{parent} and #{child} canot be related in #{relation} as the former is not in the graph"
                assert graph.has_vertex?(child),  "#{parent} and #{child} canot be related in #{relation} as the latter is not in the graph"
                assert parent.child_object?(child, relation), "#{child} is not a child of #{parent} in #{relation}"
                if !info.empty?
                    assert_equal info.first, parent[child, relation], "info differs"
                end
            end

            def refute_child_of(parent, child, relation)
                assert_same parent.relation_graphs, child.relation_graphs, "#{parent} and #{child} cannot be related as they are not acting on the same relation graphs"
                graph = parent.relation_graph_for(relation)
                refute(graph.has_vertex?(parent) && graph.has_vertex?(child) && parent.child_object?(child, relation))
            end

	    # Starts +task+ and checks it succeeds
	    def assert_succeeds(task, *args)
		control_priority do
		    if !task.kind_of?(Roby::Task)
			execution_engine.execute do
			    plan.add_mission_task(task = planner.send(task, *args))
			end
		    end

		    assert_event_emission([task.event(:success)], [], nil) do
			plan.add_permanent_task(task)
			task.start! if task.pending?
			yield if block_given?
		    end
		end
	    end

	    def control_priority
		old_priority = Thread.current.priority 
		Thread.current.priority = execution_engine.thread.priority + 1

		yield
	    ensure
		Thread.current.priority = old_priority if old_priority
	    end

	    # This assertion fails if the relative error between +found+ and
	    # +expected+is more than +error+
	    def assert_relative_error(expected, found, error, msg = "")
		if expected == 0
		    assert_in_delta(0, found, error, "comparing #{found} to #{expected} in #{msg}")
		else
		    assert_in_delta(0, (found - expected) / expected, error, "comparing #{found} to #{expected} in #{msg}")
		end
	    end

	    # This assertion fails if +found+ and +expected+ are more than +dl+
	    # meters apart in the x, y and z coordinates, or +dt+ radians apart
	    # in angles
	    def assert_same_position(expected, found, dl = 0.01, dt = 0.01, msg = "")
		assert_relative_error(expected.x, found.x, dl, msg)
		assert_relative_error(expected.y, found.y, dl, msg)
		assert_relative_error(expected.z, found.z, dl, msg)
		assert_relative_error(expected.yaw, found.yaw, dt, msg)
		assert_relative_error(expected.pitch, found.pitch, dt, msg)
		assert_relative_error(expected.roll, found.roll, dt, msg)
	    end

            def assert_droby_compatible(object, local_marshaller: DRoby::Marshal.new, remote_marshaller: DRoby::Marshal.new)
                droby = local_marshaller.dump(object)
                dumped =
                    begin Marshal.dump(droby)
                    rescue Exception => e
                        require 'roby/droby/logfile/writer'
                        obj, exception = Roby::DRoby::Logfile::Writer.find_invalid_marshalling_object(droby)
                        raise e, "#{obj} cannot be marshalled: #{exception.message}", exception.backtrace
                    end
                loaded = Marshal.load(dumped)
                remote_marshaller.local_object(loaded)
            end

            # A [ivar, positive, negative, deadline] tuple representing an event
            # assertion
            attr_reader :watched_events

            # Tests for events in +positive+ and +negative+ and returns
            # the set of failing events if the assertion has finished.
            # If the set is empty, it means that the assertion finished
            # successfully
            def self.event_watch_result(positive, negative, deadline = nil)
                if deadline && deadline < Time.now
                    return nil, "timed out waiting for #{positive.map(&:to_s).join(", ")} to happen"
                end
                if positive_ev = positive.find { |ev| ev.emitted? }
                    return "#{positive_ev} happened", nil
                end
                failure = negative.find_all { |ev| ev.emitted? }
                if !failure.empty?
                    return "#{failure} happened", nil
                end
                if positive.all? { |ev| ev.unreachable? }
                    return nil, "all positive events are unreachable"
                end

                nil
            end

            # This method is inserted in the control thread to implement
            # Assertions#assert_events
            def verify_watched_events
                return if !watched_events

                ivar, *assertion = *watched_events
                success, error = Assertions.event_watch_result(*assertion)
                if success
                    ivar.set(success)
                    @watched_events = nil
                elsif error
                    ivar.fail(error)
                    @watched_events = nil
                end
            end

            def assert_fails_to_start(task)
                yield
                assert task.failed_to_start?
            end

            def create_exception_matcher(localized_error_type, original_exception: nil, failure_point: nil)
                matcher = localized_error_type.match
                if original_exception
                    matcher.with_original_exception(original_exception)
                end
                if matcher.respond_to?(:with_ruby_exception) && matcher.ruby_exception_class == Exception
                    if original_exception
                        matcher.with_ruby_exception(original_exception)
                    else
                        matcher.without_ruby_exception
                    end
                end
                if failure_point
                    matcher.with_origin(failure_point)
                end
            end


            def assert_free_event_emission_failed(
                exception = EmissionFailed, original_exception: nil, failure_point: EventGenerator, direct: false, &block)
                assert_notifies_free_event_exception(exception, failure_point: failure_point)
                assert_free_event_exception_warning do
                    assert_event_emission_failed(
                        exception, original_exception: original_exception, failure_point: failure_point, direct: direct, &block)
                end
            end
            def assert_event_emission_failed(
                exception = EmissionFailed, original_exception: nil, failure_point: EventGenerator, direct: false)
                assert_event_exception(exception, original_exception: original_exception, failure_point: failure_point, direct: direct) do
                    yield
                end
            end

            def assert_free_event_command_failed(
                exception = CommandFailed, original_exception: nil, failure_point: EventGenerator, direct: false, &block)
                assert_notifies_free_event_exception(exception, failure_point: failure_point)
                assert_free_event_exception_warning do
                    assert_event_command_failed(
                        exception, original_exception: original_exception, failure_point: failure_point, direct: direct, &block)
                end
            end
            def assert_event_command_failed(
                exception = CommandFailed, original_exception: nil, failure_point: EventGenerator, direct: false)
                assert_event_exception(exception, original_exception: original_exception, failure_point: failure_point, direct: direct) do
                    yield
                end
            end

            def assert_task_fails_to_start(task, matcher, failure_point: task.start_event, original_exception: nil, tasks: [])
                exception = assert_handled_exception(matcher, failure_point: failure_point, original_exception: original_exception, tasks: tasks + [task], execution_engine: task.execution_engine) do
                    yield
                end
                assert task.failed_to_start?
                assert_equal exception, task.failure_reason
            end


            def assert_fatal_exception(matcher, failure_point: Task, original_exception: nil, tasks: [])
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)

                error = nil
                messages = capture_log(plan.execution_engine, :warn) do
                    flexmock(execution_engine).should_receive(:notify_exception).at_least.once.
                        with(ExecutionEngine::EXCEPTION_FATAL, matcher.to_execution_exception_matcher, tasks.to_set)
                    error = assert_raises(matcher) do
                        yield
                    end
                end
                assert_equal "1 unhandled fatal exceptions, involving #{tasks.size} tasks that will be forcefully killed", messages[0]
                task_messages = tasks.flat_map { |t| PP.pp(t, '').chomp.split("\n") }.to_set
                assert_equal task_messages, messages[1..-1].to_set
                error
            end

            def exception_assertion_guess_execution_engine(explicit_engine, failure_point, tasks)
                if explicit_engine
                    explicit_engine
                elsif failure_point.respond_to?(:execution_engine)
                    failure_point.execution_engine
                elsif t = tasks.first
                    t.execution_engine
                else self.execution_engine
                end
            end

            def assert_handled_exception(matcher, failure_point: Task, original_exception: nil, tasks: [], execution_engine: nil)
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                execution_engine = exception_assertion_guess_execution_engine(
                    execution_engine, failure_point, tasks)

                error = nil
                flexmock(execution_engine).should_receive(:notify_exception).at_least.once.
                    with(ExecutionEngine::EXCEPTION_HANDLED, matcher.to_execution_exception_matcher, tasks.to_set).
                    and_return do |_, execution_exception, _|
                        error = execution_exception.exception
                    end
                yield
                error
            end

            def assert_nonfatal_exception(matcher, failure_point: Task, original_exception: nil, tasks: [])
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                execution_engine = exception_assertion_guess_execution_engine(
                    execution_engine, failure_point, tasks)

                error = nil
                messages = capture_log(plan.execution_engine, :warn) do
                    flexmock(execution_engine).should_receive(:notify_exception).at_least.once.
                        with(ExecutionEngine::EXCEPTION_NONFATAL, matcher.to_execution_exception_matcher, tasks.to_set)
                    error = assert_raises(matcher) do
                        yield
                    end
                end
                assert_equal ["1 unhandled non-fatal exceptions"], messages
                error
            end

            def assert_logs_exception_with_backtrace(exception_m, logger, level)
                flexmock(Roby).should_receive(:log_exception_with_backtrace).once.
                    with(exception_m, logger, level)
            end


            def assert_free_event_exception_warning
                messages = capture_log(execution_engine, :warn) do
                    yield
                end
                assert_equal ["1 free event exceptions"], messages
            end

            def assert_notifies_free_event_exception(error, failure_point: nil)
                flexmock(execution_engine).should_receive(:notify_exception).
                    with(ExecutionEngine::EXCEPTION_FREE_EVENT, error.to_execution_exception_matcher, ->(generators) { generators.to_a == [failure_point] }).
                    once
            end

            def assert_free_event_exception(matcher, original_exception: nil, failure_point: EventGenerator, direct: false, execution_engine: nil, &block)
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                execution_engine = exception_assertion_guess_execution_engine(
                    execution_engine, failure_point, [])
                flexmock(execution_engine).should_receive(:notify_exception).
                    with(ExecutionEngine::EXCEPTION_FREE_EVENT, matcher.to_execution_exception_matcher, Set[failure_point]).
                    once

                error = nil
                messages = capture_log(execution_engine, :warn) do
                    error = assert_event_exception(matcher, original_exception: original_exception,
                                           failure_point: failure_point, direct: direct, execution_engine: execution_engine, &block)
                end
                assert_equal ["1 free event exceptions"], messages
                error
            end

            def assert_event_exception(matcher, original_exception: nil, failure_point: EventGenerator, direct: false, execution_engine: nil)
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                execution_engine = exception_assertion_guess_execution_engine(
                    execution_engine, failure_point, [])

                if !direct
                    flexmock(execution_engine).should_receive(:add_error).
                        with(matcher).once.pass_thru
                end

                assert_raises(matcher) do
                    yield
                end
            end
        end
    end
end

