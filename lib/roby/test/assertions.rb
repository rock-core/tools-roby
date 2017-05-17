module Roby
    module Test
        module Assertions
            def setup
                @expected_events = Array.new
                super
            end

            def teardown
                @expected_events.each do |m, args|
                    if !plan.event_logger.has_received_event?(m, *args)
                        flunk("expected to receive a log event #{m}(#{args.map(&:to_s).join(", ")}) but did not. Received:\n  " +
                        plan.event_logger.received_events.
                            find_all { |m, _, args| m.to_s !~ /timegroup/ }.
                            map { |m, time, args| "#{m}(#{args.map(&:to_s).join(", ")})" }.
                            join("\n  "))
                    end
                end
                super
            end

            def assert_sets_equal(expected, actual)
                if !(diff = (expected - actual)).empty?
                    flunk("expects two sets to be equal, but #{expected} is missing #{diff.size} expected elements:\n  #{diff.to_a.map(&:to_s).join(", ")}")
                elsif !(diff = (actual - expected)).empty?
                    flunk("expects two sets to be equal, but #{actual} has #{diff.size} more elements than expected:\n  #{diff.to_a.map(&:to_s).join(", ")}")
                end
            end

            # Capture log output from one logger and returns it
            #
            # Note that it currently does not "de-shares" loggers
            #
            # @param [Logger,#logger] a logger object, or an object that holds
            #   one
            # @param [Symbol] level the name of the logging method (e.g. :warn)
            # @return [Array<String>]
            def capture_log(object, level)
                FlexMock.use(object) do |mock|
                    __capture_log(mock, level, &proc)
                end
            end

            def __capture_log(mock, level)
                Roby.disable_colors

                if mock.respond_to?(:logger)
                    object_logger = mock.logger
                else
                    object_logger = mock
                end

                capture = Array.new
                original_level = object_logger.level
                level_value = Logger.const_get(level.upcase)
                if original_level > level_value
                    object_logger.level = level_value
                end

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
                capture
            ensure
                Roby.enable_colors_if_available
                object_logger.level = original_level
            end

            # Verifies that the given exception object does not raise when
            # pretty-printed
            #
            # When using minitest, this is called by
            # {MinitestHelpers#assert_raises}
            def assert_exception_can_be_pretty_printed(e)
                PP.pp(e, "") # verify that the exception can be pretty-printed, all Roby exceptions should
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
            # @param [Boolean,nil] enable_scheduler whether the scheduler should be
            #   enabled. nil leaves the current setting unchanged.
            # @param [Boolean] garbage_collect_pass whether it should run
            #   garbage collection
            #
            # @yieldparam yields to a block that should perform the action that
            #   should cause the emission
            def assert_event_emission(positive = [], negative = [], msg = nil, timeout = 5, enable_scheduler: nil, garbage_collect_pass: true)
                expect_execution do
                    yield if block_given?
                end.with_setup do
                    self.timeout timeout
                    self.scheduler enable_scheduler
                    self.garbage_collect garbage_collect_pass
                end.to do
                    Array(positive).each { |g| emit g }
                    Array(negative).each { |g| not_emit g }
                end
            end

            # @api private
            #
            # Internal helper for {#assert_event_emission} and
            # {#assert_event_becomes_unreachable}
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

                deadline = Time.now + timeout
                ivar = Concurrent::IVar.new
                while !ivar.complete?
                    success, error = Assertions.event_watch_result(positive, negative, deadline)
                    if success
                        ivar.set(success)
                    elsif error
                        ivar.fail(error)
                    end

                    if !ivar.complete?
                        process_events(garbage_collect_pass: garbage_collect_pass)
                    end
                end
                return ivar, unreachability_reason
            end

            # @api private
            #
            # Formats a message that describes why an event became unreachable
            #
            # @return [String]
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

            # Asserts that the given task is added to the quarantine
            def assert_task_quarantined(task, timeout: 5)
                expect_execution { yield }.with_config { timeout(timeout) }.
                    to { quarantine task }
            end

            # Verifies that the provided event becomes unreachable within a
            # certain time frame
            #
            # @param [EventGenerator] event
            # @param [Float] timeout in seconds
            # @yield a block of code that performs the action that should turn
            #   the event into unreachable
            def assert_event_becomes_unreachable(generator, timeout: 5, &block)
                expect_execution { yield }.with_config { timeout(timeout) }.
                    to { make_unreachable(generator) }
                generator.unreachability_reason
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

            # Asserts that two tasks are in a parent-child relationship in a
            # specific relation
            #
            # @param [Roby::Task] parent the parent task
            # @param [Roby::Task] child the child task
            # @param [Relations::Models::Graph] relation the relation
            # @param [#===] info optional object used to match the edge
            #   information. Leave empty if it should not be matched. Note that
            #   giving 'nil' will match against nil
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

            # Asserts that two tasks are not a parent-child relationship in a
            # specific relation
            def refute_child_of(parent, child, relation)
                assert_same parent.relation_graphs, child.relation_graphs, "#{parent} and #{child} cannot be related as they are not acting on the same relation graphs"
                graph = parent.relation_graph_for(relation)
                refute(graph.has_vertex?(parent) && graph.has_vertex?(child) && parent.child_object?(child, relation))
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

            def droby_local_marshaller
                @droby_local_marshaller ||= DRoby::Marshal.new
            end

            def droby_remote_marshaller
                @droby_remote_marshaller ||= DRoby::Marshal.new
            end

            def droby_transfer(object, local_marshaller: self.droby_local_marshaller, remote_marshaller: self.droby_remote_marshaller)
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


            # Asserts that an object can marshalled an unmarshalled by the DRoby
            # protocol
            #
            # It does not verify that the resulting objects are equal as they
            # usually are not
            #
            # @param [Object] object the object to test against
            # @param [DRoby::Marshal] local_marshaller the local marshaller,
            #   which will be used to marshal 'object'
            # @param [DRoby::Marshal] remote_marshaller the remote marshaller,
            #   which will be used to unmarshal the marshalled version of
            #   'object'
            # @return [Object] the 'remote' object created from the unmarshalled
            #   droby representation
            def assert_droby_compatible(object, local_marshaller: self.droby_local_marshaller, remote_marshaller: self.droby_remote_marshaller)
                droby_transfer(object, local_marshaller: local_marshaller,
                               remote_marshaller: remote_marshaller)
            end

            # @api private
            #
            # A [ivar, positive, negative, deadline] tuple representing an event
            # assertion
            attr_reader :watched_events

            # @api private
            #
            # Helper method that creates a matching object for localized errors
            #
            # @param [LocalizedError] localized_error_type the error model to
            #   match
            # @param [Exception,nil] original_exception an original exception
            #   to match, for exceptions that transform exceptions into other
            #   (e.g. CodeError)
            # @param [Task,EventGenerator] failure_point the exceptions' failure
            #   point
            # @return [#===] an object that can match an execution exception
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
                matcher
            end


            # Asserts that an exception involving a free event is raised
            #
            # @yield the block that should cause the exception
            # @param (see create_exception_matcher)
            def assert_free_event_emission_failed(exception = EmissionFailed, original_exception: nil, failure_point: EventGenerator, &block)
                assert_event_emission_failed(exception, original_exception: original_exception, failure_point: failure_point, &block)
            end

            # Asserts that an event's emission failed
            #
            # @yield the block that should cause the exception
            # @param (see create_exception_matcher)
            def assert_event_emission_failed(exception = EmissionFailed, original_exception: nil, failure_point: EventGenerator, execution_engine: nil, &block)
                assert_event_exception(
                    exception, original_exception: original_exception,
                    failure_point: failure_point,
                    execution_engine: execution_engine, &block)
            end

            # Asserts that a free event's command failed
            #
            # @yield the block that should cause the exception
            # @param (see create_exception_matcher)
            def assert_free_event_command_failed(exception = CommandFailed, original_exception: nil, failure_point: EventGenerator, execution_engine: nil, &block)
                assert_event_exception(
                    exception, original_exception: original_exception,
                    failure_point: failure_point,
                    execution_engine: execution_engine, &block)
            end

            # Asserts that an event's command failed
            #
            # @yield the block that should cause the exception
            # @param (see create_exception_matcher)
            def assert_event_command_failed(exception = CommandFailed, original_exception: nil, failure_point: EventGenerator, execution_engine: nil, &block)
                assert_event_exception(
                    exception, original_exception: original_exception,
                    failure_point: failure_point,
                    execution_engine: execution_engine, &block)
            end

            # Asserts that an exception involving a free event is raised
            def assert_free_event_exception(matcher, original_exception: nil, failure_point: EventGenerator, execution_engine: nil, &block)
                assert_event_exception(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point,
                    execution_engine: execution_engine, &block)
            end

            # Asserts that an exception involving an event is raised
            #
            # @yield the block that should cause the exception
            # @param (see create_exception_matcher)
            def assert_event_exception(matcher, original_exception: nil, failure_point: EventGenerator, execution_engine: nil)
                execution_engine = exception_assertion_guess_execution_engine(
                    execution_engine, failure_point, [])

                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                expect_execution { yield if block_given? }.to { have_error_matching matcher }
            end

            # Asserts that a task fails to start
            #
            # @param [Task] the task
            # @param (see assert_handled_exception)
            # @param [Boolean] direct whether the failure is registered directly
            #   (i.e. the code-under-test will call #emit_failed directly) or is
            #   transformed from an event exception involving the task's start
            #   event by Roby's default exception handling mechanisms.
            def assert_task_fails_to_start(task, matcher, failure_point: task.start_event, original_exception: nil, tasks: [])
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                expect_execution { yield if block_given? }.to { fail_to_start task }
                task.failure_reason
            end

            # Asserts that a fatal exception is raised
            #
            # @yield the code that should cause the exception to be raised
            # @param (see create_exception_matcher)
            # @param [Enumerable<Task>] tasks forming the exception's trace
            # @return [LocalizedError] the exception
            def assert_fatal_exception(matcher, failure_point: Task, original_exception: nil, tasks: [], kill_tasks: tasks)
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                expect_execution { yield if block_given? }.to { have_error_matching matcher }.exception
            end

            # Asserts that an exception is raised and handled
            #
            # @yield the code that should cause the exception to be raised and
            #   handled
            # @param (see create_exception_matcher)
            # @param [Enumerable<Task>] tasks forming the exception's trace
            # @return [LocalizedError] the exception
            def assert_handled_exception(matcher, failure_point: Task, original_exception: nil, tasks: [])
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                expect_execution { yield if block_given? }.to { have_handled_error_matching matcher }
            end

            # Asserts that a non-fatal exception is raised
            #
            # @yield the code that should cause the exception to be raised
            # @param (see create_exception_matcher)
            # @param [Enumerable<Task>] tasks forming the exception's trace
            # @return [LocalizedError] the exception
            def assert_nonfatal_exception(matcher, failure_point: Task, original_exception: nil, tasks: [])
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                expect_execution { yield }.to { have_error_matching matcher }
            end

            # Asserts that Roby logs an exception with its backtrace
            #
            # @param [#===] exception_m an object matching the expected
            #   exception
            # @param logger the logger object
            # @param [Symbol] level the log level (e.g. :warn, :info, ...)
            def assert_logs_exception_with_backtrace(exception_m, logger, level)
                flexmock(Roby).should_receive(:log_exception_with_backtrace).once.
                    with(exception_m, logger, level)
            end

            # Asserts that the block issues a free event exception warning
            #
            # @yield the block whose output is being asserted
            def assert_free_event_exception_warning
                messages = capture_log(execution_engine, :warn) do
                    yield
                end
                assert_equal ["1 free event exceptions"], messages
            end

            # Asserts that the engine received a free event exception
            # notification
            def assert_notifies_free_event_exception(matcher, failure_point: nil)
                flexmock(execution_engine).should_receive(:notify_exception).
                    with(ExecutionEngine::EXCEPTION_FREE_EVENT,
                         *roby_make_flexmock_exception_matcher(matcher, [failure_point])).
                    once
            end

            def assert_logs_event(event_name, *args)
                @expected_events << [event_name, args]
            end

            # Asserts that an error is added using {ExecutionEngine#add_error}
            #
            # @param (see create_exception_matcher)
            # @yield the block that should cause the error to be added
            # @return [LocalizedError]
            def assert_adds_error(matcher, original_exception: nil, failure_point: PlanObject)
                matcher = create_exception_matcher(
                    matcher, original_exception: original_exception,
                    failure_point: failure_point)
                execution_engine = exception_assertion_guess_execution_engine(
                    execution_engine, failure_point, [])
                
                caught_error = nil
                FlexMock.use(execution_engine) do |mock|
                    mock.should_receive(:add_error).with(matcher, any).
                        once.
                        and_return { |error, *_| caught_error = error }
                    yield
                end
                caught_error
            end

            # Asserts that an error is added using
            # {ExecutionEngine#add_framework_error}
            def assert_adds_framework_error(matcher)
                caught_error = nil
                FlexMock.use(execution_engine) do |ee_mock|
                    ee_mock.should_receive(:add_framework_error).with(matcher, any).once.
                        and_return { |error, _| caught_error = error }
                    yield
                end
                caught_error
            end

            # @api private
            #
            # Guess which execution engine is involved in an exception assertion
            #
            # @param [ExecutionEngine,nil] explicit_engine an engine that is
            #   explicitely provided (and which is obviously picked)
            # @param [PlanObject,nil] failure_point the expected failure point
            # @param [Array<Task>] tasks the expected exception trace
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

            # @api private
            #
            # Helper matcher used to provide a better error message in the
            # various exception assertions
            FlexmockExceptionMatcher = Struct.new :matcher do
                def ===(exception)
                    return true if matcher === exception
                    if self.class.describe? && (description = matcher.describe_failed_match(exception))
                        Roby.warn  "expected exception to match #{matcher}, but #{description}"
                    end
                    false
                end
                def inspect; to_s end
                def to_s; matcher.to_s; end

                @describe = false
                def self.describe?
                    @describe
                end
                def self.describe=(flag)
                    @describe = flag
                end
            end

            # @api private
            #
            # Helper matcher used to provide a better error message in the
            # various exception assertions
            FlexmockExceptionTasks = Struct.new :tasks do
                def ===(tasks)
                    self.tasks.to_set == tasks
                end
                def inspect; to_s end
                def to_s; "involved_tasks(#{tasks.to_a.map(&:to_s).join(", ")})" end
            end

            # @api private
            #
            # Helper method that creates exception matchers that provide better
            # error messages, for the benefit of the exception assertions
            def roby_make_flexmock_exception_matcher(matcher, tasks)
                return FlexmockExceptionMatcher.new(matcher.to_execution_exception_matcher),
                    FlexmockExceptionTasks.new(tasks.to_set)
            end
            # Assert that a state machine transitions
            def assert_state_machine_transition(state_machine_task, to_state: Regexp.new, timeout: 5, start: true)
                state_machines = state_machine_task.coordination_objects.
                    find_all { |obj| obj.kind_of?(Coordination::ActionStateMachine) }
                if state_machines.empty?
                    raise ArgumentError, "#{state_machine_task} has no state machines"
                end

                if to_state.respond_to?(:to_str) && !to_state.end_with?('_state')
                    to_state = "#{to_state}_state"
                end

                done = false
                state_machines.each do |m|
                    m.on_transition do |_, new_state|
                        if to_state === new_state.name
                            done = true
                        end
                    end
                end
                yield if block_given?
                process_events_until(timeout: timeout, garbage_collect_pass: false) do
                    done
                end
                roby_run_planner(state_machine_task)
                if start
                    assert_event_emission state_machine_task.current_task_child.start_event
                end
                state_machine_task.current_task_child
            end

            def validate_state_machine(task_or_action, &block)
                ValidateStateMachine.new(self, task_or_action).evaluate(&block)
            end
        end
    end
end

