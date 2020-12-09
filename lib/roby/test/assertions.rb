# frozen_string_literal: true

module Roby
    module Test
        module Assertions
            def setup
                @expected_events = []
                super
            end

            def teardown
                @expected_events.each do |m, args|
                    unless plan.event_logger.has_received_event?(m, *args)
                        received_events_s =
                            plan
                            .event_logger.received_events
                            .find_all { |ev_name, _| ev_name.to_s !~ /timegroup/ }
                            .map do |ev_name, _time, ev_args|
                                "#{ev_name}(#{ev_args.map(&:to_s).join(', ')})"
                            end
                            .join('\n  ')

                        flunk("expected to receive a log event "\
                              "#{m}(#{args.map(&:to_s).join(', ')}) but did not. "\
                              "Received:\n  #{received_events_s}")
                    end
                end
                super
            end

            # Perform tests on an action state machine
            #
            # @param [Roby::Task,Roby::Actions::Action] task_or_action a task that holds
            #   a state machine, or a state machine action
            # @param block a block evaluated in a {ValidateStateMachine} context
            def validate_state_machine(task_or_action, &block)
                machine = ValidateStateMachine.new(self, task_or_action)
                unless task_or_action.respond_to?(:running?) && task_or_action.running?
                    machine.start
                end
                machine.evaluate(&block)
            end

            # Checks that an exception's #pretty_print method passes without
            # exceptions
            def assert_exception_can_be_pretty_printed(e)
                # verify that the exception can be pretty-printed, all Roby
                # exceptions should
                PP.pp(e, "".dup)
            end

            # Better equality test for sets
            #
            # It displays the difference between the two sets
            def assert_sets_equal(expected, actual)
                if !(diff = (expected - actual)).empty?
                    flunk("expects two sets to be equal, but #{expected} is "\
                          "missing #{diff.size} expected elements:\n  "\
                          "#{diff.to_a.map(&:to_s).join(', ')}")
                elsif !(diff = (actual - expected)).empty?
                    flunk("expects two sets to be equal, but #{actual} has "\
                          "#{diff.size} more elements than expected:\n  "\
                          "#{diff.to_a.map(&:to_s).join(', ')}")
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
            def capture_log(object, level, &block)
                FlexMock.use(object) do |mock|
                    __capture_log(mock, level, &block)
                end
            end

            def __capture_log(mock, level)
                Roby.disable_colors

                object_logger =
                    if mock.respond_to?(:logger)
                        mock.logger
                    else
                        mock
                    end

                capture = []
                original_level = object_logger.level
                level_value = Logger.const_get(level.upcase)
                object_logger.level = level_value if original_level > level_value

                mock.should_receive(level)
                    .and_return do |msg|
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

            # Verifies that a given event is unreachable, optionally checking
            # its unreachability reason
            #
            # @return the unreachability reason
            def assert_event_is_unreachable(event, reason: nil)
                assert event.unreachable?,
                       "#{event} was expected to be unreachable but is not"
                if reason
                    assert(reason === event.unreachability_reason,
                           "the unreachability of #{event} was expected to "\
                           "match #{reason} but it is #{event.unreachability_reason}")
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
                assert_same parent.relation_graphs, child.relation_graphs,
                            "#{parent} and #{child} cannot be related as they "\
                            "are not acting on the same relation graphs"
                graph = parent.relation_graph_for(relation)
                assert graph.has_vertex?(parent),
                       "#{parent} and #{child} canot be related in #{relation}"\
                       " as the former is not in the graph"
                assert graph.has_vertex?(child),
                       "#{parent} and #{child} canot be related in #{relation}"\
                       " as the latter is not in the graph"
                assert parent.child_object?(child, relation),
                       "#{child} is not a child of #{parent} in #{relation}"
                unless info.empty?
                    assert_equal info.first, parent[child, relation], "info differs"
                end
            end

            # Asserts that two tasks are not a parent-child relationship in a
            # specific relation
            def refute_child_of(parent, child, relation)
                assert_same parent.relation_graphs, child.relation_graphs,
                            "#{parent} and #{child} cannot be related as they "\
                            "are not acting on the same relation graphs"
                graph = parent.relation_graph_for(relation)
                refute(graph.has_vertex?(parent) && graph.has_vertex?(child) &&
                       parent.child_object?(child, relation))
            end

            # This assertion fails if the relative error between +found+ and
            # +expected+is more than +error+
            def assert_relative_error(expected, found, error, msg = "")
                if expected == 0
                    assert_in_delta(0, found, error,
                                    "comparing #{found} to #{expected} in #{msg}")
                else
                    assert_in_delta(0, (found - expected) / expected, error,
                                    "comparing #{found} to #{expected} in #{msg}")
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

            def droby_to_remote(object, local_marshaller: droby_local_marshaller)
                droby = local_marshaller.dump(object)
                dumped =
                    begin Marshal.dump(droby)
                    rescue Exception => e
                        require "roby/droby/logfile/writer"
                        obj, exception = Roby::DRoby::Logfile::Writer
                                         .find_invalid_marshalling_object(droby)
                        raise e, "#{obj} cannot be marshalled: "\
                                 "#{exception.message}", exception.backtrace
                    end
                Marshal.load(dumped)
            end

            def droby_transfer(object,
                               local_marshaller: droby_local_marshaller,
                               remote_marshaller: droby_remote_marshaller)
                loaded = droby_to_remote(object, local_marshaller: local_marshaller)
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
            def assert_droby_compatible(
                object, local_marshaller: droby_local_marshaller,
                remote_marshaller: droby_remote_marshaller,
                bidirectional: false
            )
                remote_object = droby_transfer(
                    object,
                    local_marshaller: local_marshaller,
                    remote_marshaller: remote_marshaller
                )

                return remote_object unless bidirectional

                local_object = droby_transfer(
                    remote_object,
                    local_marshaller: remote_marshaller,
                    remote_marshaller: local_marshaller
                )
                [remote_object, local_object]
            end

            # Expects the event logger to receive the given message
            #
            # The assertion is validated on teardown
            def assert_logs_event(event_name, *args)
                @expected_events << [event_name, args]
            end

            # @!group Deprecated assertions replaced by expect_execution

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
            def create_exception_matcher(localized_error_type,
                                         original_exception: nil,
                                         failure_point: nil)
                matcher = localized_error_type.match
                matcher.with_original_exception(original_exception) if original_exception
                if matcher.respond_to?(:with_ruby_exception) && matcher.ruby_exception_class == Exception
                    if original_exception
                        matcher.with_ruby_exception(original_exception)
                    else
                        matcher.without_ruby_exception
                    end
                end
                matcher.with_origin(failure_point) if failure_point
                matcher
            end

            # @deprecated use #expect_execution { ... }.to { emit event } instead
            def assert_event_emission(
                positive = [], negative = [], _msg = nil, timeout = 5,
                enable_scheduler: nil, garbage_collect_pass: true
            )
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to { emit event } instead"
                expect_execution { yield if block_given? }
                    .timeout(timeout)
                    .scheduler(enable_scheduler)
                    .garbage_collect(garbage_collect_pass)
                    .to do
                        not_emit(*Array(negative))
                        emit(*Array(positive))
                    end
            end

            # @deprecated use #expect_execution { ... }.to { quarantine task }
            def assert_task_quarantined(task, timeout: 5)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to { quarantine task } "\
                                     "instead"
                expect_execution { yield }
                    .timeout(timeout)
                    .to { quarantine task }
            end

            # @deprecated use #expect_execution { ... }
            #                 .to { become_unreachable generator }
            def assert_event_becomes_unreachable(generator, timeout: 5)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ become_unreachable generator } instead"
                expect_execution { yield }
                    .timeout(timeout)
                    .to { become_unreachable generator }
            end

            # @deprecated use expect_execution { ... }.to { have_error_matching ... }
            def assert_free_event_emission_failed(exception = EmissionFailed,
                                                  original_exception: nil,
                                                  failure_point: EventGenerator, &block)
                Roby.warn_deprecated(
                    "#{__method__} is deprecated, use instead expect_execution { ... }"\
                    ".to { have_error_matching ... }"
                )
                assert_event_emission_failed(
                    exception,
                    original_exception: original_exception,
                    failure_point: failure_point, &block
                )
            end

            # @deprecated use expect_execution { ... }
            #                 .to { have_error_matching EmissionFailed.match.... }
            def assert_event_emission_failed(exception = EmissionFailed,
                                             original_exception: nil,
                                             failure_point: EventGenerator,
                                             execution_engine: nil, &block)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ have_error_matching EmissionFailed.match... } "\
                                     "instead"
                assert_event_exception(
                    exception,
                    original_exception: original_exception,
                    failure_point: failure_point,
                    execution_engine: execution_engine, &block
                )
            end

            # @deprecated use expect_execution { ... }
            #                 .to { have_error_matching CommandFailed.match... }
            def assert_free_event_command_failed(exception = CommandFailed,
                                                 original_exception: nil,
                                                 failure_point: EventGenerator,
                                                 execution_engine: nil, &block)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ have_error_matching CommandFailed.match... } "\
                                     "instead"

                assert_event_exception(
                    exception,
                    original_exception: original_exception,
                    failure_point: failure_point,
                    execution_engine: execution_engine, &block
                )
            end

            # @deprecated use expect_execution { ... }
            #                 .to { have_error_matching CommandFailed.match... }
            def assert_event_command_failed(exception = CommandFailed,
                                            original_exception: nil,
                                            failure_point: EventGenerator,
                                            execution_engine: nil, &block)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ have_error_matching CommandFailed.match... } "\
                                     "instead"

                assert_event_exception(
                    exception,
                    original_exception: original_exception,
                    failure_point: failure_point,
                    execution_engine: execution_engine, &block
                )
            end

            # @deprecated use expect_execution { ... }.to { have_error_matching ... }
            def assert_free_event_exception(matcher,
                                            original_exception: nil,
                                            failure_point: EventGenerator,
                                            execution_engine: nil, &block)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ have_error_matching ... } instead"

                assert_event_exception(
                    matcher,
                    original_exception: original_exception,
                    failure_point: failure_point,
                    execution_engine: execution_engine, &block)
            end

            # @deprecated use expect_execution { ... }.to { have_error_matching ... }
            def assert_event_exception(matcher,
                                       original_exception: nil,
                                       failure_point: EventGenerator)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ have_error_matching ... } instead"

                matcher = create_exception_matcher(
                    matcher,
                    original_exception: original_exception,
                    failure_point: failure_point
                )
                expect_execution { yield if block_given? }
                    .to { have_error_matching matcher }
            end

            # @deprecated use expect_execution { ... }.to { fail_to_start ... }
            def assert_task_fails_to_start(task, matcher,
                                           failure_point: task.start_event,
                                           original_exception: nil,
                                           tasks: [])
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ fail_to_start ... } instead"
                matcher = create_exception_matcher(
                    matcher,
                    original_exception: original_exception,
                    failure_point: failure_point
                )
                expect_execution { yield if block_given? }
                    .to { fail_to_start task, matcher }
                task.failure_reason
            end

            # @deprecated use expect_execution { ... }.to { have_error_matching ... }
            def assert_fatal_exception(matcher,
                                       failure_point: Task,
                                       original_exception: nil,
                                       tasks: [],
                                       kill_tasks: tasks,
                                       garbage_collect: false)
                Roby.warn_deprecated "#{__method__} is deprecated, "\
                                     "use #expect_execution { ... }.to "\
                                     "{ have_error_matching ... } instead"
                matcher = create_exception_matcher(
                    matcher,
                    original_exception: original_exception,
                    failure_point: failure_point
                )
                expect_execution { yield if block_given? }
                    .garbage_collect(garbage_collect)
                    .to { have_error_matching matcher }
                    .exception
            end

            # @deprecated use #expect_execution { ... }
            #                 .to { have_handled_error_matching ... }
            def assert_handled_exception(matcher,
                                         failure_point: Task,
                                         original_exception: nil,
                                         tasks: [])
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ have_handled_error_matching ... } instead"
                matcher = create_exception_matcher(
                    matcher,
                    original_exception: original_exception,
                    failure_point: failure_point
                )
                expect_execution { yield if block_given? }
                    .to { have_handled_error_matching matcher }
            end

            # @deprecated use expect_execution { ... }.to { have_error_matching ... }
            def assert_nonfatal_exception(matcher,
                                          failure_point: Task,
                                          original_exception: nil,
                                          tasks: [])
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ have_error_matching ... } instead"
                matcher = create_exception_matcher(
                    matcher,
                    original_exception: original_exception,
                    failure_point: failure_point
                )
                expect_execution { yield }
                    .to { have_error_matching matcher }
            end

            # @deprecated
            def assert_logs_exception_with_backtrace(exception_m, logger, level)
                flexmock(Roby).should_receive(:log_exception_with_backtrace)
                              .once
                              .with(exception_m, logger, level)
            end

            # @deprecated
            def assert_free_event_exception_warning
                Roby.warn_deprecated "#{__method__} is deprecated, and has no "\
                                     "replacements. It is not needed when using "\
                                     "the expect_execution harness"
                messages = capture_log(execution_engine, :warn) do
                    yield
                end
                assert_equal ["1 free event exceptions"], messages
            end

            # @deprecated
            def assert_notifies_free_event_exception(matcher, failure_point: nil)
                Roby.warn_deprecated "#{__method__} is deprecated, and has no "\
                                     "replacements. It is not needed when using "\
                                     "the expect_execution harness"
                flexmock(execution_engine)
                    .should_receive(:notify_exception)
                    .with(
                        ExecutionEngine::EXCEPTION_FREE_EVENT,
                        *roby_make_flexmock_exception_matcher(matcher, [failure_point])
                    ).once
            end

            # @deprecated use #expect_execution { ... }
            #                 .to { have_error_matching ... } instead
            def assert_adds_error(matcher,
                                  original_exception: nil,
                                  failure_point: PlanObject)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ have_error_matching ... } instead"

                matcher = create_exception_matcher(
                    matcher,
                    original_exception: original_exception,
                    failure_point: failure_point
                )
                expect_execution { yield }
                    .to { have_error_matching matcher }
            end

            # @deprecated use #expect_execution { ... }
            #                 .to { have_framework_error_matching ... } instead
            def assert_adds_framework_error(matcher)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#expect_execution { ... }.to "\
                                     "{ have_framework_error_matching ... } instead"
                expect_execution { yield }
                    .to { have_framework_error_matching matcher }
            end

            # @api private
            #
            # Helper matcher used to provide a better error message in the
            # various exception assertions
            FlexmockExceptionMatcher = Struct.new :matcher do
                def ===(exception)
                    return true if matcher === exception

                    if self.class.describe?
                        if (description = matcher.describe_failed_match(exception))
                            Roby.warn "expected exception to match #{matcher}, "\
                                      "but #{description}"
                        end
                    end
                    false
                end

                def inspect
                    to_s
                end

                def to_s
                    matcher.to_s
                end

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

                def inspect
                    to_s
                end

                def to_s
                    "involved_tasks(#{tasks.to_a.map(&:to_s).join(', ')})"
                end
            end

            # @api private
            #
            # Helper method that creates exception matchers that provide better
            # error messages, for the benefit of the exception assertions
            def roby_make_flexmock_exception_matcher(matcher, tasks)
                [FlexmockExceptionMatcher.new(matcher.to_execution_exception_matcher),
                 FlexmockExceptionTasks.new(tasks.to_set)]
            end

            # @!endgroup Deprecated assertions replaced by expect_execution

            # @deprecated use {#validate_state_machine} instead
            def assert_state_machine_transition(state_machine_task,
                                                to_state: Regexp.new,
                                                timeout: 5,
                                                start: true)
                Roby.warn_deprecated "#{__method__} is deprecated, use "\
                                     "#validate_state_machine instead"
                state_machines =
                    state_machine_task
                    .each_coordination_object
                    .find_all { |obj| obj.kind_of?(Coordination::ActionStateMachine) }
                if state_machines.empty?
                    raise ArgumentError, "#{state_machine_task} has no state machines"
                end

                if to_state.respond_to?(:to_str) && !to_state.end_with?("_state")
                    to_state = "#{to_state}_state"
                end

                done = false
                state_machines.each do |m|
                    m.on_transition do |_, new_state|
                        done = true if to_state === new_state.name
                    end
                end
                yield if block_given?
                process_events_until(timeout: timeout, garbage_collect_pass: false) do
                    done
                end
                roby_run_planner(state_machine_task)
                if start
                    assert_event_emission(
                        state_machine_task.current_task_child.start_event
                    )
                end
                state_machine_task.current_task_child
            end

            # Checks the result of pretty-printing an object
            #
            # The method will ignore non-empty blank lines as output of the
            # pretty-print, and an empty line at the end. The reason is that
            # pretty-print will add spaces at the nest level after a breakable,
            # which is hard (if not impossible) to represent when using an
            # editor that cleans trailing whitespaces
            def assert_pp(expected, object)
                actual = PP.pp(object, "".dup).chomp
                actual = actual.split("\n").map do |line|
                    if line =~ /^\s+$/
                        ""
                    else
                        line
                    end
                end.join("\n")
                assert_equal expected, actual
            end

            # Run a capture block and return the result
            #
            # This is typically used in an action interface spec this way:
            #
            #    task = my_action(**arguments)
            #    task = run_planners(task)
            #    result = run_capture(task, 'capture_name', context: current_pose)
            #
            # Note that a capture's name is the name of the local variable it is
            # assigned to. For instance, in the following example, the capture's
            # name is 'c'
            #
            #    action_state_machine 'test' do
            #       task = state(something)
            #       c = capture(task.success_event) do |e|
            #       end
            #
            # @param [Roby::Task] task the roby task that is supporting the capture
            # @param [String] capture_name the name of the capture, which is the
            #    name of the local variable it is assigned to
            # @param [Object] context the context of the event passed to the
            #    capture, in the common case where the capture only reads the
            #    event context. Use either 'context' or 'event', but not both.
            # @param [Roby::Event] event the event that should be passed to the
            #    capture. Use either 'context' or 'event', but not both
            def run_state_machine_capture(task, capture_name, context: [], event: nil)
                if event && (!context.kind_of?(Array) || !context.empty?)
                    raise ArgumentError, "cannot pass both context and event"
                end

                (capture, state_machine) = find_state_machine_capture(task, capture_name)
                unless capture
                    raise ArgumentError, "no capture named '#{capture_name}' in any "\
                        "state machine associated with #{task}"
                end

                event ||= Struct.new(:context).new(Array(context))
                capture.filter(state_machine, event)
            end

            # @api private
            #
            # Finds a capture with the given name in the state machine(s)
            # attached to a task
            #
            # @return [(Coordination::Models::Capture, Coordination::ActionStateMachine)]
            def find_state_machine_capture(task, capture_name)
                task.each_coordination_object do |object|
                    next unless object.model.respond_to?(:each_capture)

                    object.model.each_capture do |c, _|
                        return [c, object] if c.name == capture_name
                    end
                end
                nil
            end
        end
    end
end
