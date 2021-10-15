# frozen_string_literal: true

require "roby/test/self"
require "./test/mockups/tasks"

module Roby
    describe ExecutionEngine do
        after do
            if @engine_thread&.alive?
                stop_engine_in_thread
            end
        end

        describe "#scheduler=" do
            it "refuses to be set to nil" do
                e = assert_raises(ArgumentError) do
                    execution_engine.scheduler = nil
                end
                assert_equal "cannot set the scheduler to nil. You can disable the current scheduler with .enabled = false instead, or set it to Schedulers::Null.new",
                             e.message
            end
            it "does set it if not nil" do
                execution_engine.scheduler = Schedulers::Null.new(plan)
            end
        end

        describe "event_ordering" do
            it "is not cleared if events without precedence relations are added to the plan" do
                flexmock(execution_engine.event_ordering).should_receive(:clear).never
                plan.add(EventGenerator.new)
            end
            it "is cleared if a new precedence relation is added between events in the plan" do
                parent, child = EventGenerator.new, EventGenerator.new
                plan.add [parent, child]
                flexmock(execution_engine.event_ordering).should_receive(:clear).once
                parent.add_precedence child
            end
            it "is cleared if events linked through the precedence relation are added to the plan" do
                parent, child = EventGenerator.new, EventGenerator.new
                parent.add_precedence child
                flexmock(execution_engine.event_ordering).should_receive(:clear).once
                plan.add parent
            end
            it "is not cleared when a precedence relation is removed" do
                parent, child = EventGenerator.new, EventGenerator.new
                plan.add [parent, child]
                parent.add_precedence child
                flexmock(execution_engine.event_ordering).should_receive(:clear).never
                parent.remove_precedence child
            end
        end

        describe "event propagation" do
            it "calls handlers before propagating signals" do
                source, target = EventGenerator.new, EventGenerator.new(true)
                plan.add(source)
                source.signals target
                mock = flexmock
                source.on { mock.called_source }
                target.on { mock.called_target(source.emitted?) }
                mock.should_receive(:called_source).once.globally.ordered
                mock.should_receive(:called_target).once.with(true).globally.ordered
                execute { source.emit }
            end

            it "calls handlers before propagating forwards" do
                source, target = EventGenerator.new, EventGenerator.new
                plan.add(source)
                source.forward_to target
                mock = flexmock
                source.on { mock.called_source }
                target.on { mock.called_target(source.emitted?) }
                mock.should_receive(:called_source).once.globally.ordered
                mock.should_receive(:called_target).once.with(true).globally.ordered
                execute { source.emit }
            end
        end

        it "removes queued emissions whose task event target has been finalized" do
            plan.add(task = Roby::Tasks::Simple.new)
            execution_engine.gather_propagation do
                task.start_event.emit
                plan.remove_task(task)
                assert !execution_engine.has_queued_events?
            end
        end

        it "removes queued emissions whose free event target has been finalized" do
            plan.add(generator = Roby::EventGenerator.new)
            execution_engine.gather_propagation do
                generator.emit
                plan.remove_free_event(generator)
                assert !execution_engine.has_queued_events?
            end
        end

        describe "promise handling" do
            it "queues promises in the #waiting_work list" do
                p = execution_engine.promise {}
                assert execution_engine.waiting_work.include?(p)
            end

            it "removes completed promises from #waiting_work" do
                p = execution_engine.promise {}
                p.on_error {}
                p.execute
                promises, = execution_engine.join_all_waiting_work
                assert_equal [p], promises
                refute execution_engine.waiting_work.include?(p)
            end

            it "leaves non-completed promises within #waiting_work" do
                p = execution_engine.promise {}
                flexmock(p).should_receive(:complete?).and_return(false)
                p.execute
                assert_equal [], execution_engine.process_waiting_work
                assert execution_engine.waiting_work.include?(p)
            end

            it "adds a promise error as a framework error if it is not handled" do
                e = ArgumentError.new
                p = execution_engine.promise { raise e }
                p.execute
                flexmock(execution_engine).should_receive(:add_framework_error)
                    .with(e, String).once
                execution_engine.join_all_waiting_work
                refute execution_engine.waiting_work.include?(p)
            end

            it "adds a promise error as a framework error if there are error handlers, "\
               "but themselves raised" do
                e = ArgumentError.new("e")
                f = ArgumentError.new("f")
                p = execution_engine.promise { raise e }
                p.on_error { raise f }
                p.execute
                flexmock(execution_engine).should_receive(:add_framework_error)
                    .with(e, String).once
                flexmock(execution_engine).should_receive(:add_framework_error)
                    .with(f, String).once
                execution_engine.join_all_waiting_work

                refute_includes execution_engine.waiting_work, p
            end

            it "does not add a handled promise error as a framework error" do
                e = ArgumentError.new
                p = execution_engine.promise { raise e }
                p.on_error {}
                p.execute
                flexmock(execution_engine).should_receive(:add_framework_error).never
                promises, = execution_engine.join_all_waiting_work
                assert promises.include?(p)
                refute execution_engine.waiting_work.include?(p)
            end
        end

        describe "#finalized_event" do
            before do
                plan.add(@event = Roby::EventGenerator.new)
                execute { plan.remove_free_event(@event) }
            end

            it "marks the event as unreachable" do
                assert @event.unreachable?
            end
            it "reports 'finalized' as the unreachability reason" do
                assert_equal "finalized", @event.unreachability_reason
            end
        end

        describe "#propagation_context" do
            it "sets the sources to the given set" do
                execution_engine.gather_propagation do
                    execution_engine.propagation_context([event = flexmock]) do
                        assert_equal [event], execution_engine.propagation_sources
                    end
                end
            end
            it "restores the sources to their original value if the block returns normally" do
                execution_engine.gather_propagation do
                    execution_engine.propagation_context(original_sources = [flexmock]) do
                        execution_engine.propagation_context(sources = [flexmock]) do
                            assert_equal sources, execution_engine.propagation_sources
                        end
                        assert_equal original_sources, execution_engine.propagation_sources
                    end
                end
            end
            it "restores the sources to their original value if the block raises" do
                assert_raises(RuntimeError) do
                    execution_engine.gather_propagation do
                        execution_engine.propagation_context(original_sources = [flexmock]) do
                            begin
                                execution_engine.propagation_context([flexmock]) do
                                    raise
                                end
                            ensure
                                assert_equal original_sources, execution_engine.propagation_sources
                            end
                        end
                    end
                end
            end
            it "raises if called outside a propagation context" do
                e = assert_raises(InternalError) do
                    execution_engine.propagation_context([]) do
                    end
                end
                assert_equal "not in a gathering context in #propagation_context",
                             e.message
            end
            it "leaves the sources to their value if the propagation context check triggers" do
                execution_engine.instance_variable_set(:@propagation_sources, sources = [flexmock])
                assert_raises(InternalError) do
                    execution_engine.propagation_context([]) {}
                end
                assert_equal sources, execution_engine.propagation_sources
            end
        end

        describe "#quit" do
            it "sets the quitting flag but not forced_exit?" do
                execution_engine.quit
                assert execution_engine.quitting?
                refute execution_engine.forced_exit?
                execution_engine.quit
                assert execution_engine.quitting?
                refute execution_engine.forced_exit?
            end
        end

        describe "#force_quit" do
            it "sets both quitting flag and forced_exit?" do
                execution_engine.force_quit
                assert execution_engine.quitting?
                assert execution_engine.forced_exit?
            end
        end

        describe "#reset" do
            it "resets the quitting flag" do
                execution_engine.quit
                execution_engine.reset
                refute execution_engine.quitting?
            end
            it "does nothing if the EE is not quitting" do
                execution_engine.reset
                refute execution_engine.quitting?
            end
        end

        describe "#event_loop" do
            describe "exit behaviour" do
                it "quits when receiving a Interrupt" do
                    execution_engine.once do
                        execution_engine.add_framework_error(Interrupt.exception, "test")
                    end
                    flexmock(execution_engine).should_expect do |m|
                        m.error.with_any_args
                        m.info.with_any_args
                        m.fatal("Received interruption request").once
                        m.fatal("Interrupt again in 10s to quit without cleaning up").once
                        m.clear.at_least.once
                    end
                    execution_engine.event_loop
                end

                it "does not forcefully quit when receiving two Interrupts closer than the dead zone parameter" do
                    Timecop.freeze do
                        # The plan is 'clean' when #clear returns nil
                        clear_return = []
                        flexmock(execution_engine).should_receive(:clear).and_return { clear_return }
                            .at_least.once
                        execution_engine.once do
                            execution_engine.add_framework_error(Interrupt.exception, "test")
                            execution_engine.once do
                                Timecop.freeze(5)
                                execution_engine.add_framework_error(Interrupt.exception, "test")
                                execution_engine.once do
                                    clear_return = nil
                                end
                            end
                        end
                        flexmock(execution_engine).should_expect do |m|
                            m.error.with_any_args
                            m.info.with_any_args
                            m.fatal("Received interruption request").once
                            m.fatal("Interrupt again in 10s to quit without cleaning up").once
                            m.fatal("Still 5s before interruption will quit without cleaning up").once
                        end
                        execution_engine.event_loop
                    end
                end

                it "does forcefully quit when receiving two Interrupts spaced by more than the dead zone parameter" do
                    Timecop.freeze do
                        # The plan is 'clean' when #clear returns nil
                        clear_return = []
                        flexmock(execution_engine).should_receive(:clear).and_return { clear_return }
                            .at_least.once
                        execution_engine.once do
                            execution_engine.add_framework_error(Interrupt.exception, "test")
                            execution_engine.once do
                                Timecop.freeze(12)
                                execution_engine.add_framework_error(Interrupt.exception, "test")
                            end
                        end
                        flexmock(execution_engine).should_expect do |m|
                            m.error.with_any_args
                            m.info.with_any_args
                            m.fatal("Received interruption request").once
                            m.fatal("Interrupt again in 10s to quit without cleaning up").once
                            m.fatal("Quitting without cleaning up").once
                        end
                        execution_engine.event_loop
                    end
                end
            end
        end

        describe "#garbage_collect" do
            it "stops running tasks" do
                plan.add(task = Roby::Tasks::Simple.new)
                expect_execution { task.start! }
                    .garbage_collect(true)
                    .to do
                        finish task
                        finalize task
                    end
            end

            it "removes pending tasks" do
                plan.add(task = Roby::Tasks::Simple.new)
                expect_execution.garbage_collect(true)
                    .to do
                        not_emit task.start_event
                        finalize task
                    end
            end

            it "ignores finishing tasks" do
                task_m = Roby::Task.new_submodel do
                    event :stop do |context|
                    end
                end
                plan.add(task = task_m.new)
                expect_execution { task.start! }.garbage_collect(true)
                    .to { achieve { task.finishing? } }
                execute_one_cycle
                execute { task.stop_event.emit }
            end

            it "inhibits propagation between two garbage-collected events" do
                Roby::Plan.logger.level = Logger::WARN
                a, b = prepare_plan discover: 2, model: Tasks::Simple
                a.stop_event.signals b.stop_event
                expect_execution { a.start! }
                    .garbage_collect(true)
                    .to do
                        finalize a
                        finalize b
                        not_emit b.start_event
                    end
            end

            it "inhibits exceptions originating from garbage-collected tasks" do
                plan.add(event = EventGenerator.new)
                event.when_unreachable do
                    plan.add_error(LocalizedError.new(event))
                end
                expect_execution.garbage_collect(true).to_run
            end

            it "inhibits exceptions originating from garbage-collected tasks" do
                plan.add(task = Roby::Tasks::Simple.new)
                task.stop_event.when_unreachable do
                    plan.add_error(LocalizedError.new(task))
                end
                expect_execution.garbage_collect(true).to_run
            end

            it "inhibits exceptions originating from garbage-collected tasks whose events have exceptions" do
                plan.add(task = Roby::Tasks::Simple.new)
                task.stop_event.when_unreachable do
                    plan.add_error(LocalizedError.new(task.stop_event))
                end
                expect_execution.garbage_collect(true).to_run
            end

            it "does not finalize a task which is strongly related to another, "\
               "this other task being pending but returning false in #can_finalize?" do
                plan.add(task = Tasks::Simple.new)
                can_finalize = false
                flexmock(task).should_receive(:can_finalize?).and_return { can_finalize }

                agent_m = Tasks::Simple.new_submodel do
                    event :ready
                end
                task.executed_by(agent = agent_m.new)
                execute { execution_engine.garbage_collect }

                assert task.plan
                assert agent.plan

                # This is the actual manifestation of the bug this test has
                # been written for. The agent was getting garbage-collected,
                # which led to a non-finalized task that should have an agent
                # to not have one
                assert task.execution_agent

                can_finalize = true
                expect_execution { execution_engine.garbage_collect }
                    .to do
                        finalize agent
                        finalize task
                    end
            ensure
                can_finalize = true
            end

            it "does garbage-collect tasks passed in the force_gc set, "\
               "regardless of whether they are in the unneeded_tasks set" do
                plan.add_mission_task(task = Tasks::Simple.new)
                execute { task.start! }

                expect_execution { plan.execution_engine.garbage_collect([task]) }
                    .to { emit task.stop_event }
            end

            describe "handling of the quarantine" do
                after do
                    execute do
                        plan.quarantined_tasks.each do |t|
                            t.stop_event.emit if t.running?
                        end
                    end
                end

                it "does not attempt to terminate a running quarantined task" do
                    plan.add(task = Tasks::Simple.new)
                    execute { task.start! }
                    task.quarantined!
                    warn_log = FlexMock.use(task) do |mock|
                        mock.should_receive(:stop!).never
                        capture_log(execution_engine, :warn) do
                            execute { execution_engine.garbage_collect }
                        end
                    end
                    assert_equal ["GC: #{task} is running but in quarantine"],
                                 warn_log
                    execute { task.stop! }
                end
                it "finalizes a pending quarantined task" do
                    plan.add(task = Tasks::Simple.new)
                    task.quarantined!
                    expect_execution { execution_engine.garbage_collect }
                        .to { finalize task }
                end
                it "finalizes a quarantined task that failed to start" do
                    plan.add(task = Tasks::Simple.new)
                    execute { task.failed_to_start!(Exception.new) }
                    task.quarantined!
                    expect_execution { execution_engine.garbage_collect }
                        .to { finalize task }
                end
                it "finalizes a finished quarantined task" do
                    plan.add(task = Tasks::Simple.new)
                    task.quarantined!
                    expect_execution do
                        task.start!
                        task.stop!
                    end
                        .garbage_collect(true)
                        .to { finalize task }
                end
                it "quarantines a task that cannot be stopped" do
                    plan.add(uninterruptible_task = Task.new_submodel.new)
                    execute { uninterruptible_task.start_event.emit }
                    log = capture_log(execution_engine, :warn) do
                        execute { execution_engine.garbage_collect }
                    end
                    assert_equal(
                        ["GC: #{uninterruptible_task} cannot be stopped, "\
                         "putting in quarantine"], log
                    )

                    assert uninterruptible_task.quarantined?
                    execute { uninterruptible_task.stop_event.emit }
                end

                # This worked around a Heisenbug a long time ago ... need to make
                # sure that it still happens
                it "quarantines a task whose stop event is controllable but for "\
                   "which #stop! is not defined" do
                    plan.add(task = Tasks::Simple.new)
                    execute { task.start_event.emit }
                    flexmock(task).should_receive(:respond_to?).with(:stop!).and_return(false)
                    flexmock(task).should_receive(:respond_to?).pass_thru

                    warn_log = capture_log(execution_engine, :warn) do
                        execute { execution_engine.garbage_collect }
                    end

                    assert_equal(
                        ["something fishy: #{task}/stop is controlable but there "\
                         "is no #stop! method, putting in quarantine"], warn_log
                    )
                    assert task.quarantined?
                    execute { task.stop_event.emit }
                end

                it "generates a QuarantinedTaskError error for mission tasks" do
                    plan.add_mission_task(task = Tasks::Simple.new)
                    execute { task.start_event.emit }
                    expect_execution { task.quarantined! }
                        .to do
                            have_error_matching QuarantinedTaskError.match.with_origin(task)
                        end
                end

                it "generates a QuarantinedTaskError error for permanent tasks" do
                    plan.add_permanent_task(task = Tasks::Simple.new)
                    execute { task.start_event.emit }
                    expect_execution { task.quarantined! }
                        .to do
                            have_error_matching QuarantinedTaskError.match.with_origin(task)
                        end
                end

                it "generates a QuarantinedTaskError error for tasks that are in use" do
                    plan.add(parent_task = Tasks::Simple.new)
                    parent_task.depends_on(task = Tasks::Simple.new)
                    execute do
                        parent_task.start_event.emit
                        task.start_event.emit
                    end
                    expect_execution { task.quarantined! }
                        .to do
                            have_error_matching(
                                QuarantinedTaskError.match.with_origin(task)
                            )
                        end

                    execute { parent_task.stop_event.emit }
                end

                it "does not generate a QuarantinedTaskError error for parents tasks "\
                   "that are themselves in quarantine" do
                    plan.add(parent_task = Tasks::Simple.new)
                    parent_task.depends_on(task = Tasks::Simple.new)
                    execute do
                        parent_task.start_event.emit
                        task.start_event.emit
                    end

                    execute do
                        parent_task.quarantined!
                        task.quarantined!
                    end

                    execute do
                        parent_task.stop_event.emit
                        task.stop_event.emit
                    end
                end

                it "does not generate a QuarantinedTaskError error "\
                   "for a standalone task" do
                    plan.add(task = Tasks::Simple.new)
                    execute { task.start_event.emit }
                    execute { task.quarantined! }
                end
            end
        end

        describe "#add_error" do
            attr_reader :task_m, :root, :child, :localized_error_m, :recorder, :other_root, :child, :child_e

            before do
                @task_m = Roby::Task.new_submodel { argument :name, default: nil }
                plan.add(@root = @task_m.new(name: "root"))
                root.depends_on(@child = @task_m.new(name: "child"))
                @localized_error_m = Class.new(LocalizedError)
                @recorder = flexmock

                root.depends_on(@child = task_m.new(name: "child"))
                plan.add(@other_root = task_m.new(name: "other_root"))
                other_root.depends_on(child)
                @child_e = localized_error_m.new(child).to_execution_exception
            end

            def assert_raises_error_with_trace(*trace, &block)
                expect_execution(&block).to do
                    have_error_matching localized_error_m.match
                        .with_origin(child)
                        .to_execution_exception_matcher
                        .with_trace(*trace)
                end
            end

            it "adds the error with no parents by default" do
                assert_raises_error_with_trace(child => [other_root, root]) do
                    execution_engine.add_error(child_e)
                end
            end

            it "allows providing specific parents" do
                assert_raises_error_with_trace(child => root) do
                    execution_engine.add_error(child_e, propagate_through: [root])
                end
            end

            it "does not propagate the exception if an empty parent set is given" do
                assert_raises_error_with_trace do
                    execution_engine.add_error(child_e, propagate_through: [])
                end
            end

            it "raises and logs the exception if not called within a exception gathering context" do
                assert_logs_exception_with_backtrace(localized_error_m.to_execution_exception_matcher, execution_engine, :fatal)
                assert_raises(ExecutionEngine::NotPropagationContext) do
                    execution_engine.add_error(child_e)
                end
            end
        end

        describe "#gather_framework_errors" do
            attr_reader :error_m

            before do
                @error_m = Class.new(RuntimeError)
            end

            it "raises the exceptions registerd by #add_framework_error by default" do
                flexmock(execution_engine).should_receive(:fatal).with("Application error in test").once
                assert_raises(error_m, display_exceptions: true) do
                    assert_logs_exception_with_backtrace(error_m, execution_engine, :fatal)
                    execution_engine.gather_framework_errors "test" do
                        execution_engine.add_framework_error(error_m.exception, "test")
                    end
                end
            end
            it "raises on the downmost call if called recursively" do
                flexmock(execution_engine).should_receive(:fatal).with("Application error in inside").once
                recorder = flexmock
                recorder.should_receive(:called).once
                assert_raises(error_m, display_exceptions: true) do
                    assert_logs_exception_with_backtrace(error_m, execution_engine, :fatal)

                    execution_engine.gather_framework_errors "test" do
                        execution_engine.gather_framework_errors "inside" do
                            execution_engine.add_framework_error(error_m.exception, "inside")
                        end
                        recorder.called
                    end
                end
            end
            it "registers the exceptions it catches itself" do
                recorder = flexmock
                recorder.should_receive(:called).once
                log_message = capture_log(execution_engine, :fatal) do
                    assert_raises(error_m, display_exceptions: true) do
                        assert_logs_exception_with_backtrace(error_m, execution_engine, :fatal)
                        execution_engine.gather_framework_errors "test" do
                            FlexMock.use(execution_engine) do |mock|
                                mock.should_receive(:add_framework_error).with(error_m, "inside").once.pass_thru
                                execution_engine.gather_framework_errors "inside" do
                                    raise error_m
                                end
                            end
                            recorder.called
                        end
                    end
                end
                assert_equal ["Application error in inside"], log_message
            end

            describe "raise_caught_exceptions: false" do
                it "returns the exceptions instead of raising them" do
                    error = error_m.exception
                    caught_errors = execution_engine.gather_framework_errors "test", raise_caught_exceptions: false do
                        raise error
                    end
                    assert_equal [[error, "test"]], caught_errors
                end
                it "returns them on the downmost call only if called recursively" do
                    error = error_m.exception
                    caught_errors = execution_engine.gather_framework_errors "test", raise_caught_exceptions: false do
                        execution_engine.gather_framework_errors "inside" do
                            execution_engine.add_framework_error(error, "inside")
                        end
                    end
                    assert_equal [[error, "inside"]], caught_errors
                end
                it "registers the exceptions it catches itself" do
                    error = error_m.exception
                    caught_errors = execution_engine.gather_framework_errors "test", raise_caught_exceptions: false do
                        execution_engine.gather_framework_errors "inside" do
                            raise error
                        end
                    end
                    assert_equal [[error, "inside"]], caught_errors
                end
            end
        end

        describe "#gather_errors" do
            attr_reader :error

            before do
                plan.add(task = Task.new)
                @error = Class.new(LocalizedError).new(task).to_execution_exception
            end
            it "converts the exception into an ExecutionException" do
                flexmock(error.exception).should_receive(:to_execution_exception)
                    .once.and_return(ee = flexmock)
                errors = execution_engine.gather_errors do
                    plan.add_error(error.exception)
                end
                assert_equal [[ee, nil]], errors
            end
            it "returns all exceptions registered with #add_errors" do
                errors = execution_engine.gather_errors do
                    plan.add_error(error)
                end
                assert_equal [[error, nil]], errors
            end
            it "returns the propagate_through set if given" do
                through = flexmock
                errors = execution_engine.gather_errors do
                    plan.add_error(error, propagate_through: through)
                end
                assert_equal [[error, through]], errors
            end
            it "resets the set of errors so that the next call to #add_errors returns false" do
                execution_engine.gather_errors { plan.add_error(error) }
                assert_equal([], execution_engine.gather_errors {})
            end
            it "raises if called recursively" do
                execution_engine.gather_errors do
                    assert_raises(InternalError) do
                        execution_engine.gather_errors {}
                    end
                end
            end
        end

        describe "#propagate_exception_in_plan" do
            attr_reader :task_m, :root, :child, :localized_error_m, :recorder

            before do
                @task_m = Roby::Task.new_submodel { argument :name, default: nil }
                plan.add(@root = @task_m.new(name: "root"))
                root.depends_on(@child = @task_m.new(name: "child"))
                @localized_error_m = Class.new(LocalizedError)
                @recorder = flexmock
            end

            def match_exception(*edges, handled: nil)
                localized_error_m.to_execution_exception_matcher
                    .with_trace(*edges)
                    .handled(handled)
            end

            it "propagates a given exception up in the dependency graph and yields the exception and the task at each step, finishing by the plan" do
                child.depends_on(grandchild = task_m.new)

                exception = localized_error_m.new(grandchild).to_execution_exception
                recorder.should_receive(:call).once.with(exception, grandchild).ordered
                recorder.should_receive(:call).once.with(exception, child).ordered
                recorder.should_receive(:call).once.with(exception, root).ordered
                recorder.should_receive(:call).once.with(exception, plan).ordered
                result = execution_engine.propagate_exception_in_plan(
                    [exception]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    handled: [],
                                                    unhandled: [exception, Set[grandchild, child, root]])
            end

            it "forks and merges at the forks and merges of the dependency graph" do
                child.depends_on(grandchild1 = task_m.new(name: "grandchild1"))
                child.depends_on(grandchild2 = task_m.new(name: "grandchild2"))
                grandchild1.depends_on(leaf = task_m.new(name: "leaf"))
                grandchild2.depends_on(leaf)

                exception = localized_error_m.new(leaf).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, leaf).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(leaf, grandchild1), grandchild1).ordered(:parallel)
                recorder.should_receive(:call).once
                    .with(match_exception(leaf, grandchild2), grandchild2).ordered(:parallel)
                recorder.should_receive(:call).once
                    .with(match_exception(grandchild1, child,
                                          grandchild2, child,
                                          leaf, grandchild1,
                                          leaf, grandchild2), child).ordered
                recorder.should_receive(:call).once
                    .with(full_trace = match_exception(child, root,
                                                       grandchild1, child,
                                                       grandchild2, child,
                                                       leaf, grandchild1,
                                                       leaf, grandchild2), root).ordered
                recorder.should_receive(:call).once
                    .with(full_trace, plan).ordered

                result = execution_engine.propagate_exception_in_plan(
                    [exception]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    unhandled: [full_trace, Set[root, child, grandchild1, grandchild2, leaf]],
                                                    handled: [])
            end

            it "merges the forked exceptions as propagated to the roots and yields that with the plan" do
                plan.add(other_root = task_m.new(name: "other_root"))
                other_root.depends_on(child)

                exception = localized_error_m.new(child).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, child).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(child, root), root).ordered(:parallel)
                recorder.should_receive(:call).once
                    .with(match_exception(child, other_root), other_root).ordered(:parallel)
                recorder.should_receive(:call).once
                    .with(full_trace = match_exception(child, root,
                                                       child, other_root), plan).ordered

                result = execution_engine.propagate_exception_in_plan(
                    [exception]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    handled: [],
                                                    unhandled: [full_trace, Set[root, other_root, child]])
            end

            it "only propagates through specific parents if some are given" do
                child.depends_on(grandchild1 = task_m.new(name: "grandchild1"))
                child.depends_on(grandchild2 = task_m.new(name: "grandchild2"))
                grandchild1.depends_on(leaf = task_m.new(name: "leaf"))
                grandchild2.depends_on(leaf)

                exception = localized_error_m.new(leaf).to_execution_exception
                recorder.should_receive(:call).once
                    .with(exception, leaf).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(leaf, grandchild1), grandchild1).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(leaf, grandchild1,
                                          grandchild1, child), child).ordered
                recorder.should_receive(:call).once
                    .with(full_trace = match_exception(leaf, grandchild1,
                                                       grandchild1, child,
                                                       child, root), root).ordered
                recorder.should_receive(:call).once
                    .with(full_trace, plan).ordered

                result = execution_engine.propagate_exception_in_plan(
                    [[exception, [grandchild1]]]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    unhandled: [full_trace, Set[root, child, grandchild1, leaf]],
                                                    handled: [])
            end

            it "does go through excluded parents if other paths go through it" do
                child.depends_on(grandchild1 = task_m.new(name: "grandchild1"))
                grandchild1.depends_on(leaf = task_m.new(name: "leaf"))
                child.depends_on(leaf)

                exception = localized_error_m.new(leaf).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, leaf).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(leaf, grandchild1), grandchild1).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(leaf, grandchild1,
                                          grandchild1, child), child).ordered
                recorder.should_receive(:call).once
                    .with(full_trace = match_exception(leaf, grandchild1,
                                                       grandchild1, child,
                                                       child, root), root).ordered
                recorder.should_receive(:call).once
                    .with(full_trace, plan).ordered

                result = execution_engine.propagate_exception_in_plan(
                    [[exception, [grandchild1]]]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    unhandled: [full_trace, Set[root, child, grandchild1, leaf]],
                                                    handled: [])
            end

            it "filters out non-existing parents and warns about them" do
                plan.add(task = task_m.new(name: "task"))

                exception = localized_error_m.new(child).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, child).ordered
                recorder.should_receive(:call).once
                    .with(full_trace = match_exception(child, root), root).ordered
                recorder.should_receive(:call).once
                    .with(full_trace, plan).ordered

                messages = capture_log(execution_engine, :warn) do
                    result = execution_engine.propagate_exception_in_plan(
                        [[exception, [root, task]]]) { |*args| recorder.call(*args) }
                    assert_exception_propagation_result(result,
                                                        unhandled: [full_trace, Set[root, child]],
                                                        handled: [])
                end
                rx = Regexp.new("some parents specified for.*are actually not parents "\
                    "of #{Regexp.quote(child.to_s)}, they got filtered out")
                assert_match rx, messages[0]
                assert_equal "  #{task}", messages[1]
            end

            it "will propagate through all parents if filtering out "\
                "non-existing parents results in an empty set" do
                plan.add(task = task_m.new(name: "task"))

                exception = localized_error_m.new(child).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, child).ordered
                recorder.should_receive(:call).once
                    .with(full_trace = match_exception(child, root), root).ordered
                recorder.should_receive(:call).once
                    .with(full_trace, plan).ordered

                messages = capture_log(execution_engine, :warn) do
                    result = execution_engine.propagate_exception_in_plan(
                        [[exception, [task]]]) { |*args| recorder.call(*args) }
                    assert_exception_propagation_result(result,
                                                        unhandled: [full_trace, Set[root, child]],
                                                        handled: [])
                end
                rx = Regexp.new("some parents specified for.*are actually not parents "\
                    "of #{Regexp.quote(child.to_s)}, they got filtered out")
                assert_match rx, messages[0]
                assert_equal "  #{task}", messages[1]
            end

            it "only yields the exception origin if the parent set is empty" do
                exception = localized_error_m.new(child).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, child).ordered
                recorder.should_receive(:call).once
                    .with(match_exception, plan).ordered

                result = execution_engine.propagate_exception_in_plan(
                    [[exception, []]]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    unhandled: [match_exception, Set[child]],
                                                    handled: [])
            end

            it "stops an exception propagation if the block returns true" do
                child.depends_on(grandchild = task_m.new)

                exception = localized_error_m.new(grandchild).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, grandchild).ordered
                recorder.should_receive(:call).once
                    .with(full_trace = match_exception(grandchild, child), child).ordered
                    .and_return(true)
                result = execution_engine.propagate_exception_in_plan(
                    [exception]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    handled: [full_trace, Set[child]],
                                                    unhandled: [])
            end

            it "propagates through other branches if the exception is handled in a branch" do
                child.depends_on(grandchild1 = task_m.new(name: "grandchild1"))
                child.depends_on(grandchild2 = task_m.new(name: "grandchild2"))
                grandchild1.depends_on(leaf = task_m.new(name: "leaf"))
                grandchild2.depends_on(leaf)

                exception = localized_error_m.new(leaf).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, leaf).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(leaf, grandchild1), grandchild1).ordered(:parallel)
                recorder.should_receive(:call).once
                    .with(match_exception(leaf, grandchild2), grandchild2).ordered(:parallel)
                    .returns(true)
                recorder.should_receive(:call).once
                    .with(match_exception(grandchild1, child,
                                          leaf, grandchild1), child).ordered
                recorder.should_receive(:call).once
                    .with(full_trace = match_exception(child, root,
                                                       grandchild1, child,
                                                       leaf, grandchild1), root).ordered
                recorder.should_receive(:call).once
                    .with(full_trace, plan).ordered

                result = execution_engine.propagate_exception_in_plan(
                    [exception]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    unhandled: [full_trace, Set[root, child, grandchild1]],
                                                    handled: [match_exception(leaf, grandchild2), Set[grandchild2]])
            end

            it "reports exception handled by the plan as such" do
                exception = localized_error_m.new(child).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, child).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(child, root), root).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(child, root), plan).ordered
                    .and_return(true)

                result = execution_engine.propagate_exception_in_plan(
                    [exception]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    unhandled: [],
                                                    handled: [match_exception(child, root, handled: true), Set[plan]])
            end

            it "the plan is reported in addition to the handling tasks if multiple branches are involved" do
                plan.add(other_root = task_m.new(name: "other_root"))
                other_root.depends_on(child)

                exception = localized_error_m.new(child).to_execution_exception
                recorder.should_receive(:call).once
                    .with(match_exception, child).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(child, root), root).ordered
                    .and_return(true)
                recorder.should_receive(:call).once
                    .with(match_exception(child, other_root), other_root).ordered
                recorder.should_receive(:call).once
                    .with(match_exception(child, other_root), plan).ordered
                    .and_return(true)

                result = execution_engine.propagate_exception_in_plan(
                    [exception]) { |*args| recorder.call(*args) }
                assert_exception_propagation_result(result,
                                                    unhandled: [],
                                                    handled: [match_exception(child, root, child, other_root, handled: true), Set[root, plan]])
            end
        end

        describe "#remove_inhibited_exceptions" do
            attr_reader :task_m, :root, :child, :localized_error_m, :recorder

            before do
                @task_m = Roby::Task.new_submodel { argument :name, default: nil }
                plan.add(@root = @task_m.new(name: "root"))
                root.depends_on(@child = @task_m.new(name: "child"))
                @localized_error_m = Class.new(LocalizedError)
                @recorder = flexmock
            end

            def match_exception(*edges, handled: nil)
                localized_error_m.to_execution_exception_matcher
                    .with_trace(*edges)
                    .handled(handled)
            end

            it "does not inhibit unhandled exceptions" do
                e = localized_error_m.new(child).to_execution_exception
                result = execution_engine.remove_inhibited_exceptions([e])
                assert_exception_propagation_result(
                    result,
                    handled: [],
                    unhandled: [match_exception(child, root), Set[root, child]])
            end

            it "inhibits exceptions for which an object reports the ability to handle the error" do
                e = localized_error_m.new(child).to_execution_exception
                flexmock(root).should_receive(:handles_error?).with(e).and_return(true)
                result = execution_engine.remove_inhibited_exceptions([e])
                assert_exception_propagation_result(
                    result,
                    handled: [match_exception(child, root), Set[root]],
                    unhandled: [])
            end

            it "inhibits exceptions that have been registered with #add_fatal_exceptions_for_inhibition" do
                e = localized_error_m.new(child).to_execution_exception
                execution_engine.add_exceptions_for_inhibition([[e, [root]]])
                result = execution_engine.remove_inhibited_exceptions([e])
                assert_exception_propagation_result(
                    result,
                    handled: [match_exception(child, root), Set[root]],
                    unhandled: [])
            end
        end

        describe "#propagate_exceptions" do
            attr_reader :task_m, :root, :child, :localized_error_m, :recorder

            before do
                @task_m = Roby::Task.new_submodel { argument :name, default: nil }
                plan.add(@root = @task_m.new(name: "root"))
                root.depends_on(@child = @task_m.new(name: "child"))
                @localized_error_m = Class.new(LocalizedError)
                @recorder = flexmock
            end

            def match_exception(*edges, handled: nil)
                localized_error_m.to_execution_exception_matcher
                    .with_trace(*edges)
                    .handled(handled)
            end

            it "partitions task and free event exceptions" do
                plan.add(ev = EventGenerator.new)
                event_e = localized_error_m.new(ev).to_execution_exception
                task_e  = localized_error_m.new(root).to_execution_exception
                unhandled, free_events_exceptions, handled =
                    execution_engine.propagate_exceptions([event_e, task_e])
                assert_exception_propagation_result(
                    [unhandled, handled],
                    handled: [],
                    unhandled: [match_exception, Set[root]])
                assert_equal [[event_e, Set[ev]]], free_events_exceptions
            end

            it "removes inhibited task exceptions and do not report them as handled" do
                task_e = localized_error_m.new(root).to_execution_exception
                flexmock(execution_engine).should_receive(:remove_inhibited_exceptions)
                    .with([task_e]).and_return([[], flexmock])

                unhandled, free_events_exceptions, handled =
                    execution_engine.propagate_exceptions([task_e])
                assert_exception_propagation_result(
                    [unhandled, handled],
                    handled: [],
                    unhandled: [])
                assert_equal [], free_events_exceptions
            end

            it "passes the propagate-through information throuh the inhibition" do
                root.depends_on(child = task_m.new)
                task_e = localized_error_m.new(child).to_execution_exception
                flexmock(execution_engine).should_receive(:remove_inhibited_exceptions)
                    .with([[task_e, []]]).and_return([[[task_e, flexmock]], []])
                flexmock(execution_engine).should_receive(:propagate_exception_in_plan)
                    .with([[task_e, []]], Proc).once.pass_thru
                flexmock(execution_engine).should_receive(:propagate_exception_in_plan)
                    .pass_thru

                unhandled, free_events_exceptions, handled =
                    execution_engine.propagate_exceptions([[task_e, []]])
                assert_exception_propagation_result(
                    [unhandled, handled],
                    handled: [],
                    unhandled: [task_e, Set[child]])
                assert_equal [], free_events_exceptions
            end

            it "propagates non-inhibited task exceptions and reports the propagation result" do
                task_e = localized_error_m.new(root).to_execution_exception
                flexmock(execution_engine).should_receive(:remove_inhibited_exceptions)
                    .with([task_e]).pass_thru
                flexmock(execution_engine).should_receive(:propagate_exception_in_plan)
                    .with([[task_e, nil]], Proc).once.pass_thru
                flexmock(execution_engine).should_receive(:propagate_exception_in_plan)
                    .pass_thru

                unhandled, free_events_exceptions, handled =
                    execution_engine.propagate_exceptions([task_e])
                assert_exception_propagation_result(
                    [unhandled, handled],
                    handled: [],
                    unhandled: [task_e, Set[root]])
                assert_equal [], free_events_exceptions
            end

            it "lets tasks handle the exception" do
                task_e = localized_error_m.new(root).to_execution_exception
                flexmock(root).should_receive(:handle_exception).with(task_e)
                    .and_return(true)

                unhandled, free_events_exceptions, handled =
                    execution_engine.propagate_exceptions([task_e])
                assert_exception_propagation_result(
                    [unhandled, handled],
                    handled: [task_e, Set[root]],
                    unhandled: [])
                assert_equal [], free_events_exceptions
            end

            it "lets plan-level handlers handle the exception" do
                task_e = localized_error_m.new(root).to_execution_exception
                flexmock(plan).should_receive(:handle_exception).with(task_e)
                    .and_return(true)

                unhandled, free_events_exceptions, handled =
                    execution_engine.propagate_exceptions([task_e])
                assert_exception_propagation_result(
                    [unhandled, handled],
                    handled: [task_e, Set[plan]],
                    unhandled: [])
                assert_equal [], free_events_exceptions
            end
        end

        describe "the error propagation" do
            attr_reader :task_m, :root, :localized_error_m

            before do
                @task_m = Task.new_submodel do
                    attr_accessor :hold_stop

                    event(:stop) do |_|
                        unless hold_stop
                            stop_event.emit
                        end
                    end
                end
                task_m.argument :name, default: nil
                @localized_error_m = Class.new(LocalizedError)

                plan.add(@root = task_m.new)
                execute { root.start! }
            end
            after do
                plan.task_relation_graph_for(TaskStructure::Dependency).each_edge.to_a.each do |a, b|
                    a.remove_child b
                end
                execute do
                    plan.each_task { |t| t.stop_event.emit if t.stop_event.pending? }
                end
            end

            def match_exception(*edges, handled: nil)
                localized_error_m.to_execution_exception_matcher
                    .with_trace(*edges)
                    .handled(handled)
            end

            it "reports handled structure exceptions" do
                child = root.depends_on(task_m)
                plan.on_exception(ChildFailedError) { root.remove_child(child) }
                all_errors = execution_engine.process_events do
                    child.start_event.emit
                    child.stop_event.emit
                end
                assert_exception_and_object_set_matches(
                    [ChildFailedError, Set[child]],
                    all_errors.each_handled_error.to_a)
            end

            it "reports inhibited structure exceptions" do
                child = root.depends_on(task_m)
                plan.on_exception(ChildFailedError) { root.remove_child(child) }
                flexmock(child).should_receive(:handles_error?).and_return(true)
                all_errors = execution_engine.process_events do
                    child.start_event.emit
                    child.stop_event.emit
                end
                assert_exception_and_object_set_matches(
                    [ChildFailedError, Set[child]],
                    all_errors.each_inhibited_error.to_a)
            end

            it "raises a non-repaired structure exception even if a handler claims having handled it" do
                root_e = localized_error_m.new(root).to_execution_exception
                flexmock(plan).should_receive(:check_structure)
                    .and_return([[root_e, []]])
                flexmock(root).should_receive(:handle_exception).and_return(true)

                assert_exception_and_object_set_matches(
                    [match_exception, Set[root]],
                    execution_engine.compute_errors([]).each_fatal_error)
            end

            it "partitions the exceptions between fatal and non-fatal ones" do
                fatal_e = localized_error_m.new(root).to_execution_exception
                nonfatal_e = localized_error_m.new(root).to_execution_exception
                flexmock(nonfatal_e).should_receive(:fatal?).and_return(false)

                results = execution_engine.compute_errors([fatal_e, nonfatal_e])
                assert_exception_and_object_set_matches(
                    [fatal_e, Set[root]],
                    results.each_fatal_error)
                assert_exception_and_object_set_matches(
                    [nonfatal_e, Set[root]],
                    results.each_nonfatal_error)
            end

            it "reports the handled exceptions" do
                root_e = localized_error_m.new(root).to_execution_exception
                flexmock(root).should_receive(:handle_exception).and_return(true)

                assert_exception_and_object_set_matches(
                    [match_exception, Set[root]],
                    execution_engine.compute_errors([root_e]).each_handled_error)
            end

            describe "tasks that are being forcefully killed" do
                it "inhibits errors that have the same class and origin than the one that caused the error" do
                    root.depends_on(child = task_m.new)
                    expect_execution { execution_engine.add_error(localized_error_m.new(child)) }
                        .to { have_error_matching localized_error_m }
                    expect_execution { execution_engine.add_error(localized_error_m.new(child)) }.to_run
                end
                it "does report new errors while the task is being GCed but then inhibits them as well" do
                    root.hold_stop = true
                    root.depends_on(child = task_m.new)
                    expect_execution { execution_engine.add_error(localized_error_m.new(child)) }
                        .garbage_collect(true)
                        .to { have_error_matching localized_error_m.match.with_origin(child) }

                    new_localized_error_m = Class.new(LocalizedError)
                    expect_execution { execution_engine.add_error(new_localized_error_m.new(child)) }
                        .garbage_collect(true)
                        .to { have_error_matching new_localized_error_m.match.with_origin(child) }

                    expect_execution { execution_engine.add_error(localized_error_m.new(child)) }.to_run
                    expect_execution { execution_engine.add_error(new_localized_error_m.new(child)) }.to_run
                end
            end

            it "processes errors added during the error handling itself" do
                root.stop_event.when_unreachable do
                    execution_engine.add_error localized_error_m.new(root)
                end
                expect_execution.garbage_collect(true).to do
                    have_error_matching localized_error_m
                end
            end

            describe "exception notification" do
                attr_reader :results, :recorder

                before do
                    @recorder = flexmock
                    execution_engine.on_exception do |kind, notified_error, notified_objects|
                        recorder.notified(kind, notified_error, notified_objects)
                    end
                    flexmock(execution_engine)
                end
                after do
                    execution_engine.display_exceptions = true
                end

                def mock_compute_errors(result_set)
                    results = ExecutionEngine::PropagationInfo.new
                    results.send(result_set) << [@error = flexmock(exception: RuntimeError.new), @involved_objects = flexmock(each: [Object.new])]
                    execution_engine.should_receive(:compute_errors)
                        .and_return(results, ExecutionEngine::PropagationInfo.new)
                end

                def assert_receives_notification(notification_type)
                    recorder.should_receive(:notified).once
                        .with(notification_type, @error, @involved_objects)
                end

                it "notifies handled exceptions" do
                    mock_compute_errors :handled_errors
                    assert_receives_notification ExecutionEngine::EXCEPTION_HANDLED
                    messages = capture_log(execution_engine, :warn) do
                        execution_engine.process_events
                    end
                    assert_equal ["1 handled errors"], messages
                end

                it "notifies fatal exceptions" do
                    execution_engine.display_exceptions = false
                    execution_engine.should_receive(:add_exceptions_for_inhibition)
                    flexmock(plan).should_receive(:generate_induced_errors)
                    mock_compute_errors :fatal_errors
                    Roby.app.filter_backtraces = false
                    assert_receives_notification ExecutionEngine::EXCEPTION_FATAL
                    capture_log(execution_engine, :warn) do
                        execution_engine.process_events
                    end
                end
            end

            describe PermanentTaskError do
                it "adds a PermanentTaskError error if a mission task emits a failure event" do
                    task_m = Task.new_submodel do
                        event :specialized_failure
                        forward specialized_failure: :failed
                    end
                    plan.add_permanent_task(task = task_m.new)
                    expect_execution do
                        task.start!
                        task.specialized_failure_event.emit
                    end.to { have_error_matching PermanentTaskError.match.with_origin(task.specialized_failure_event) }
                    plan.unmark_permanent_task(task)
                end

                it "adds a PermanentTaskError if a permanent task is involved in an unhandled exception, and passes the exception" do
                    plan.add_permanent_task(root = task_m.new)
                    root.depends_on(origin = task_m.new)
                    error = localized_error_m.new(origin).to_execution_exception
                    error.propagate(origin, root)

                    error_match = localized_error_m.match.with_origin(origin)
                        .to_execution_exception_matcher

                    expect_execution { execution_engine.add_error(error) }
                        .to do
                            have_error_matching PermanentTaskError.match
                                .with_origin(root)
                                .with_original_exception(error_match)
                            have_error_matching error_match
                                .with_trace(origin, root)
                        end
                end
            end

            describe MissionFailedError do
                it "adds a MissionFailed error if a mission task emits a failure event" do
                    task_m = Task.new_submodel do
                        event :specialized_failure
                        forward specialized_failure: :failed
                    end
                    plan.add_mission_task(task = task_m.new)
                    expect_execution do
                        task.start!
                        task.specialized_failure_event.emit
                    end.to { have_error_matching MissionFailedError.match.with_origin(task.specialized_failure_event) }
                end

                it "adds a MissionFailedError if a mission task is involved in a fatal exception, and passes the exception" do
                    plan.add_mission_task(root = task_m.new)
                    root.depends_on(origin = task_m.new)
                    error = localized_error_m.new(origin).to_execution_exception
                    error.propagate(origin, root)

                    error_matcher = localized_error_m.match
                        .with_origin(origin)
                        .to_execution_exception_matcher

                    expect_execution { execution_engine.add_error(error) }
                        .to do
                            have_error_matching error_matcher
                                .with_trace(origin, root)
                            have_error_matching MissionFailedError.match
                                .with_origin(root)
                                .with_original_exception(error_matcher)
                        end
                end

                it "does not propagate MissionFailedError through the network" do
                    plan.add_mission_task(root = task_m.new)
                    plan.add_mission_task(middle = task_m.new)
                    root.depends_on(middle)
                    middle.depends_on(origin = task_m.new)
                    execute { root.start! }

                    error = localized_error_m.new(origin).to_execution_exception
                    error_matcher = localized_error_m.match
                        .with_origin(origin)
                        .to_execution_exception_matcher

                    expect_execution { execution_engine.add_error(error) }
                        .to do
                            have_error_matching error_matcher
                                .with_trace(origin, middle,
                                            middle, root)
                            have_error_matching MissionFailedError.match
                                .with_origin(root)
                                .with_original_exception(error_matcher)
                                .to_execution_exception_matcher
                                .with_empty_trace
                            have_error_matching MissionFailedError.match
                                .with_origin(middle)
                                .with_original_exception(error_matcher)
                                .to_execution_exception_matcher
                                .with_empty_trace
                        end
                    execute { root.stop_event.emit }
                end
            end

            describe "the error handling relation" do
                attr_reader :task_m, :localized_error_m, :repair_task, :root, :root_e

                before do
                    @task_m = Task.new_submodel
                    task_m.terminates
                    task_m.argument :name, default: nil
                    @localized_error_m = Class.new(LocalizedError)
                    plan.add(@root = task_m.new)
                    plan.add(@repair_task = task_m.new)
                    @root_e = localized_error_m.new(root.failed_event).to_execution_exception
                end

                it "inhibits exceptions for which an error handling task is running" do
                    flexmock(root).should_receive(:handles_error?)
                        .at_least.once.with(root_e).and_return(true)

                    result = execution_engine.remove_inhibited_exceptions([root_e])
                    assert_exception_propagation_result(
                        result,
                        handled: [match_exception, Set[root]],
                        unhandled: [])
                end

                it "does not inhibit an exception for which there is no active repair task" do
                    flexmock(root).should_receive(:handles_error?)
                        .at_least.once.with(root_e).and_return(false)

                    result = execution_engine.remove_inhibited_exceptions([root_e])
                    assert_exception_propagation_result(
                        result,
                        handled: [],
                        unhandled: [match_exception, Set[root]])
                end

                it "auto-starts a matching repair task" do
                    flexmock(root).should_receive(:find_all_matching_repair_tasks)
                        .at_least.once.with(root_e).and_return([repair_task])

                    expect_execution { execution_engine.add_error(root_e) }
                        .to do
                            have_handled_error_matching localized_error_m.match
                                .with_origin(root.failed_event)
                            emit repair_task.start_event
                        end
                end
            end

            describe "free events errors" do
                attr_reader :event, :localized_error_m

                before do
                    plan.add(@event = EventGenerator.new)
                    @localized_error_m = Class.new(LocalizedError)
                end

                it "marks the involved free events as unreachable" do
                    expect_execution { execution_engine.add_error(localized_error_m.new(event)) }
                        .to do
                            become_unreachable event
                            have_error_matching localized_error_m
                        end
                end
            end
        end

        describe "#once" do
            it "queues execution for the next event loop by default" do
                recorder = flexmock
                recorder.should_receive(:barrier).once.ordered
                recorder.should_receive(:called).once.ordered
                execute do
                    execution_engine.once do
                        execution_engine.once { recorder.called }
                    end
                end

                recorder.barrier
                execute_one_cycle
            end
            it "queues execution within the same loop with type is :propagation" do
                recorder = flexmock
                recorder.should_receive(:called).once.ordered
                execute do
                    execution_engine.once do
                        execution_engine.once(type: :propagation) { recorder.called }
                    end
                end
            end

            it "registers a framework exception on error by default" do
                error_m = Class.new(RuntimeError)
                called = false

                execution_engine.once { called = true; raise error_m }
                expect_execution.to do
                    achieve { called }
                    have_framework_error_matching error_m
                end
            end
        end

        describe "#execute" do
            def setup_test_thread(report_on_exception: true)
                thread = Thread.new do
                    if (t = Thread.current).respond_to?(:report_on_exception=)
                        t.report_on_exception = report_on_exception
                    end
                    yield
                end
                until thread.stop?
                    Thread.pass
                end
                thread
            end
            it "executes the block in the engine's thread" do
                thread = setup_test_thread do
                    execution_engine.execute { Thread.current }
                end
                expect_execution.to_run
                assert_equal Thread.current, thread.value
            end
            it "returns the block's return value" do
                thread = setup_test_thread do
                    execution_engine.execute { 42 }
                end
                expect_execution.to_run
                assert_equal 42, thread.value
            end
            it "handles multiple return values properly" do
                thread = setup_test_thread do
                    execution_engine.execute { [42, 84] }
                end
                expect_execution.to_run
                assert_equal [42, 84], thread.value
            end
            it "passes raised exceptions" do
                error_e = Class.new(RuntimeError)
                thread = setup_test_thread(report_on_exception: false) do
                    execution_engine.execute { raise error_e }
                end
                expect_execution.to_run
                assert_raises(error_e) { thread.value }
            end
            it "re-throws symbols that are explicitely listed" do
                thread = setup_test_thread do
                    catch(:test) do
                        execution_engine.execute(catch: [:test]) { throw :test, true }
                        false
                    end
                end
                expect_execution.to_run
                assert thread.value
            end
            it "handles values thrown along with the symbol" do
                thread = setup_test_thread do
                    catch(:test) do
                        execution_engine.execute(catch: [:test]) { throw :test, 42 }
                        nil
                    end
                end
                expect_execution.to_run
                assert_equal 42, thread.value
            end
        end

        describe "#has_waiting_work?" do
            it "returns false if there are no promises" do
                refute execution_engine.has_waiting_work?
            end
            it "returns false if there is an unscheduled promise" do
                execution_engine.promise {}
                refute execution_engine.has_waiting_work?
            end
            it "returns true if there is a scheduled promise" do
                execution_engine.promise {}.execute
                assert execution_engine.has_waiting_work?
            end
        end

        def assert_exception_and_object_set_matches(expected, actual,
                message = "failed to match propagation result exception and/or involved objects")
            expected = expected.each_slice(2).flat_map do |match_e, tasks_e|
                if match_e.respond_to?(:to_execution_exception_matcher)
                    match_e = match_e.to_execution_exception_matcher
                end
                [match_e, tasks_e.to_set]
            end

            actual.each do |e, affected_tasks|
                found_match_e = expected.each_slice(2).find_all { |match_e, _| match_e === e }
                found_tasks   = expected.each_slice(2).find_all { |_, tasks_e| tasks_e == affected_tasks }
                if (found_match_e & found_tasks).empty?
                    messages = [message]
                    if found_match_e.empty?
                        messages << "exception #{e} does not match expected"
                        expected.each_slice(2) do |match_e, _|
                            messages << "  #{match_e}"
                        end
                    end
                    if found_tasks.empty?
                        messages << "tasks #{affected_tasks.to_a} do not match expected"
                        expected.each_slice(2) do |_, tasks_e|
                            messages << "  #{tasks_e.to_a}"
                        end
                    end
                    flunk(messages.join("\n  "))
                end
            end
        end

        def assert_exception_propagation_result(result, handled: nil, unhandled: nil)
            assert_kind_of Array, result[0]
            assert_kind_of Array, result[1]
            if unhandled
                assert_exception_and_object_set_matches(
                    unhandled, result[0], "unhandled set mismatches")
            end
            if handled
                assert_exception_and_object_set_matches(
                    handled, result[1], "unhandled set mismatches")
            end
        end

        def start_engine_in_thread
            @engine_sync = Concurrent::CyclicBarrier.new(2)
            flexmock(execution_engine).should_receive(:event_loop).and_return do
                @engine_sync.wait
                @engine_sync.wait
            end
            @engine_thread = Thread.new { execution_engine.run }
            @engine_sync.wait
        end

        def stop_engine_in_thread
            @engine_sync.wait
            @engine_thread.join
        end

        describe "#run" do
            before do
                flexmock(execution_engine)
                execution_engine.should_receive(:event_loop).by_default
            end

            it "sets running? to true before calling the event loop" do
                execution_engine.should_receive(:event_loop).once
                    .and_return { assert execution_engine.running? }
                execution_engine.run
            end

            it "resets running? to false on quit" do
                refute execution_engine.running?
                execution_engine.run
            end

            it "raises on start if the engine is already running" do
                start_engine_in_thread
                assert_raises(ExecutionEngine::AlreadyRunning) { execution_engine.run }
            end

            it "sets the engine's thread to the calling thread" do
                start_engine_in_thread
                assert_equal @engine_thread, execution_engine.thread
            end

            it "terminates all waiting work on teardown and warns about it" do
                ivar = Concurrent::IVar.new
                flexmock(Roby).should_receive(:warn)
                    .with("forcefully terminated #{ivar} on quit")
                execution_engine.should_receive(:event_loop)
                    .and_return do
                        execution_engine.once(sync: ivar) {}
                    end
                execution_engine.run
                assert ivar.complete?
            end

            it "ignores already terminated waiting work" do
                ivar = Concurrent::IVar.new
                ivar.set nil
                flexmock(Roby).should_receive(:warn).never
                execution_engine.should_receive(:event_loop)
                    .and_return do
                        execution_engine.once(sync: ivar) {}
                    end
                execution_engine.run
            end

            it "handles the race condition that arises due to the waiting work"\
                "terminating concurrently with the attempt to terminate it" do
                ivar = Concurrent::IVar.new
                ivar.set nil
                flexmock(ivar).should_receive(complete?: false)
                flexmock(Roby).should_receive(:warn).never
                execution_engine.should_receive(:event_loop)
                    .and_return do
                        execution_engine.once(sync: ivar) {}
                    end
                execution_engine.run
            end

            it "runs the registered finalizers" do
                checker = flexmock
                checker.should_receive(:call).once
                execution_engine.finalizers << checker
                execution_engine.run
            end

            it "ignores exceptions during finalizer call, but warns about them" do
                error_e = Class.new(RuntimeError).exception("test")
                failed_finalizer = flexmock
                failed_finalizer.should_receive(:call).once
                    .and_raise(error_e)
                successful_finalizer = flexmock
                successful_finalizer.should_receive(:call).once

                execution_engine.finalizers <<
                    failed_finalizer <<
                    successful_finalizer
                log = capture_log(Roby, :warn) do
                    execution_engine.run
                end
                assert_equal "finalizer #{failed_finalizer} failed", log[0]
                assert_match(/test/, log[1])
            end
        end

        describe "#inside_control?" do
            it "returns false if called from a different thread than the run thread" do
                start_engine_in_thread
                refute execution_engine.inside_control?
            end

            it "returns true if called from within #run" do
                flexmock(execution_engine).should_receive(:event_loop)
                    .and_return { assert execution_engine.inside_control? }
                execution_engine.run
            end

            it "returns true after the engine quit" do
                flexmock(execution_engine).should_receive(:event_loop)
                execution_engine.run
                assert execution_engine.inside_control?
            end
        end

        describe "#outside_control?" do
            it "returns true if called from a different thread than the run thread" do
                start_engine_in_thread
                assert execution_engine.outside_control?
            end

            it "returns false if called from within #run" do
                flexmock(execution_engine).should_receive(:event_loop)
                    .and_return { refute execution_engine.outside_control? }
                execution_engine.run
            end

            it "returns true after the engine quit" do
                flexmock(execution_engine).should_receive(:event_loop)
                execution_engine.run
                assert execution_engine.outside_control?
            end
        end
    end

    describe "#wait_until" do
        # Helper that provides a context in which the tests can call #wait_until
        def wait_until_in_thread(generator, report_on_exception: true)
            t = Thread.new do
                t = Thread.current
                if t.respond_to?(:report_on_exception=)
                    t.report_on_exception = report_on_exception
                end
                execution_engine.wait_until(generator) do
                    yield if block_given?
                end
            end
            until t.stop?; sleep(0.01) end
            @thread = t
        end

        attr_reader :task

        before do
            plan.add_permanent_task(@task = Roby::Tasks::Simple.new)
        end

        it "blocks the caller until the event is emitted" do
            thread = wait_until_in_thread task.start_event
            execute { task.start! }
            thread.value
        end

        it "processes the block in the event thread" do
            thread = wait_until_in_thread task.start_event do
                assert_equal Thread.main, Thread.current
            end
            execute { task.start! }
            thread.value
        end

        it "returns the block's own return value" do
            ret = flexmock
            thread = wait_until_in_thread task.start_event do
                ret
            end
            execute { task.start! }
            assert_equal ret, thread.value
        end

        it "passes an exception raised within the block to the thread" do
            error = Class.new(RuntimeError)
            thread = wait_until_in_thread task.start_event, report_on_exception: false do
                raise error
            end
            execute { task.start! }
            assert_raises(error) do
                thread.value
            end
        end

        it "raises in the thread if the event is already unreachable" do
            execute { task.start_event.unreachable! }
            thread = wait_until_in_thread task.start_event,
                                          report_on_exception: false

            execute_one_cycle
            assert_raises(UnreachableEvent) { thread.value }
        end

        it "raises in the thread if the event becomes unreachable" do
            thread = wait_until_in_thread task.start_event, report_on_exception: false do
                task.start_event.unreachable!
            end
            execute_one_cycle
            assert_raises(UnreachableEvent) { thread.value }
        end
    end

    describe "#add_framework_error" do
        it "raises NotPropagationContext if called outside of a gathering context" do
            error_m = Class.new(RuntimeError)
            assert_raises(Roby::ExecutionEngine::NotPropagationContext) do
                assert_logs_exception_with_backtrace(error_m, execution_engine, :fatal)
                execution_engine.add_framework_error(error_m.exception("test"), :exceptions)
            end
        end

        it "registers the exception in the application exceptions set" do
            expected_error = Class.new(RuntimeError).exception("test error message")
            errors = execution_engine.gather_framework_errors("test", raise_caught_exceptions: false) do
                execution_engine.add_framework_error(expected_error, :exceptions)
            end
            assert_equal 1, errors.size
            error, context = errors.first
            assert_equal :exceptions, context
            assert_kind_of expected_error.class, error
            assert_equal "test error message", error.message
        end
    end

    describe "#at_cycle_end" do
        attr_reader :error_m

        before do
            @error_m = Class.new(RuntimeError)
        end

        it "registers a framework error for any exception raised" do
            called = false
            execution_engine.at_cycle_end { called = true; raise error_m }
            expect_execution.to do
                achieve { called }
                have_framework_error_matching error_m
            end
        end

        it "calls the other handlers regardless of an exception" do
            called = false
            execution_engine.at_cycle_end { raise error_m }
            execution_engine.at_cycle_end { called = true }
            expect_execution.to do
                achieve { called }
                have_framework_error_matching error_m
            end
        end
    end

    describe "propagation handlers" do
        def add_propagation_handler(**options, &block)
            @handler_ids << execution_engine.add_propagation_handler(**options, &block)
        end

        def remove_propagation_handlers
            @handler_ids.each do |id|
                execution_engine.remove_propagation_handler(id)
            end
        end

        attr_reader :recorder

        before do
            @recorder = flexmock
            @handler_ids = []
        end

        after do
            remove_propagation_handlers
        end

        describe "type: :external_events" do
            it "calls the handler exactly once per propagation cycle" do
                recorder.should_receive(:called).once
                add_propagation_handler(type: :external_events) do |plan|
                    recorder.called(plan)
                end
                execution_engine.process_events
            end

            it "calls the handler exactly once per propagation cycle" do
                recorder.should_receive(:called).twice
                add_propagation_handler(type: :external_events) do |plan|
                    recorder.called(plan)
                end
                execution_engine.process_events
                execution_engine.process_events
            end

            it "calls the propagation handler only at the beginning of the cycle" do
                recorder.should_receive(:called).once
                add_propagation_handler(type: :external_events) do |plan|
                    plan.add(ev = EventGenerator.new)
                    ev.emit
                    recorder.called(plan)
                end
                execution_engine.process_events
            end

            it "does not call the handler once removed" do
                recorder.should_receive(:called).never
                add_propagation_handler(type: :external_events) do |plan|
                    recorder.called
                end
                remove_propagation_handlers
                execution_engine.process_events
            end
        end

        describe "type: :propagation" do
            it "calls the handler at each propagation loop" do
                recorder.should_receive(:called).at_least.twice
                plan.add_permanent_event(ev = EventGenerator.new)
                add_propagation_handler(type: :propagation) do |plan|
                    unless ev.emitted?
                        ev.emit
                    end
                    recorder.called(plan)
                end
                execution_engine.process_events
            end

            it "does not call the handler once removed" do
                recorder.should_receive(:called).never
                add_propagation_handler(type: :propagation) do |plan|
                    recorder.called
                end
                remove_propagation_handlers
                execution_engine.process_events
            end
        end

        describe "type: :propagation, late: true" do
            it "calls the late handlers only when there are no emissions queued" do
                plan.add_permanent_event(event = Roby::EventGenerator.new(true))
                plan.add_permanent_event(late_event = Roby::EventGenerator.new(true))

                index = -1
                event.on { |_| recorder.event_emitted(index += 1) }
                late_event.on { |_| recorder.late_event_emitted(index += 1) }

                add_propagation_handler(type: :propagation) do |plan|
                    recorder.handler_called(index += 1)
                    unless event.emitted?
                        event.emit
                    end
                end
                add_propagation_handler(type: :propagation, late: true) do |plan|
                    recorder.late_handler_called(index += 1)
                    unless late_event.emitted?
                        late_event.emit
                    end
                end

                recorder.should_receive(:handler_called).with(0).once.ordered
                recorder.should_receive(:event_emitted).with(1).once.ordered
                recorder.should_receive(:handler_called).with(2).once.ordered
                recorder.should_receive(:late_handler_called).with(3).once.ordered
                recorder.should_receive(:late_event_emitted).with(4).once.ordered
                recorder.should_receive(:handler_called).with(5).once.ordered
                recorder.should_receive(:late_handler_called).with(6).once.ordered

                execution_engine.process_events
            end

            it "does not call the handlers once removed" do
                recorder.should_receive(:called).never
                add_propagation_handler(type: :propagation, late: true) do |plan|
                    recorder.called
                end
                remove_propagation_handlers
                execution_engine.process_events
            end
        end

        it "accepts method objects" do
            obj = Class.new do
                def called?
                    @called
                end

                def handler(plan)
                    @called = true
                end
            end.new

            add_propagation_handler(type: :external_events, &obj.method(:handler))
            execution_engine.process_events
            assert obj.called?
        end

        it "validates the callback arity" do
            mock = flexmock
            # Validate the arity
            assert_raises(ArgumentError) do
                execution_engine.add_propagation_handler(
                    &->(plan, failure) { mock.called(plan) }
                )
            end
            execution_engine.process_events
        end

        describe "error handling" do
            attr_reader :exception_m

            before do
                @exception_m = Class.new(RuntimeError)
            end

            describe "on_error: :raise" do
                it "adds the error as a framework error" do
                    recorder.should_receive(:called).once
                    add_propagation_handler on_error: :raise do |plan|
                        recorder.called
                        raise exception_m
                    end
                    expect_execution.to do
                        have_framework_error_matching exception_m
                    end
                end
            end

            describe "on_error: :disable" do
                it "removes the handler" do
                    recorder.should_receive(:called).once
                    add_propagation_handler description: "test", on_error: :disable do |plan|
                        recorder.called
                        raise exception_m
                    end
                    messages = capture_log(execution_engine, :warn) do
                        expect_execution.to_run
                    end
                    assert_equal "propagation handler test disabled because of the following error", messages.first
                end
            end

            describe "on_error: :ignore" do
                it "ignores the errors" do
                    recorder.should_receive(:called).at_least.twice
                    flexmock(Roby).should_receive(:log_exception_with_backtrace)
                        .with(exception_m, execution_engine, :warn).twice

                    add_propagation_handler description: "test", on_error: :ignore do |plan|
                        recorder.called
                        raise exception_m
                    end
                    messages = capture_log(execution_engine, :warn) do
                        execution_engine.process_events
                        execution_engine.process_events
                    end
                    assert_equal ["ignored error from propagation handler test"] * 2, messages
                end
            end
        end

        describe "#delay" do
            before do
                Timecop.freeze(@base_time = Time.now)
            end

            it "executes the block after the delay expired" do
                trigger_time = nil
                execution_engine.delayed(5) { trigger_time = Time.now }
                expect_execution.timeout(10).poll { Timecop.freeze(Time.now + 1) }
                    .to { achieve { trigger_time } }
                # NOTE: the delayed blocks are added within a once { } context
                # NOTE: the usage of #poll above makes it so that the delay is
                # NOTE: added only at base_time + 1, hence the base_time + 6
                assert_equal @base_time + 6, trigger_time
            end

            it "executes the block only once" do
                recorder = flexmock
                recorder.should_receive(:call).once
                execution_engine.delayed(5) { recorder.call }
                execute_one_cycle
                Timecop.freeze(Time.now + 6)
                execute_one_cycle
                Timecop.freeze(Time.now + 6)
                execute_one_cycle
            end

            it "does not execute the block if removed" do
                recorder = flexmock
                recorder.should_receive(:call).never
                handler = execution_engine.delayed(5) { recorder.call }
                execute_one_cycle
                Timecop.freeze(Time.now + 6)
                handler.dispose
                execute_one_cycle
            end
        end
    end
end

class TC_ExecutionEngine < Minitest::Test
    def test_gather_propagation
        e1, e2, e3 = EventGenerator.new(true), EventGenerator.new(true), EventGenerator.new(true)
        plan.add [e1, e2, e3]

        set = execution_engine.gather_propagation do
            e1.call(1)
            e1.call(4)
            e2.emit(2)
            e2.emit(3)
            e3.call(5)
            e3.emit(6)
        end
        assert_equal(
            { e1 => [1, [], [nil, [1], nil, nil, [4], nil]],
              e2 => [3, [nil, [2], nil, nil, [3], nil], []],
              e3 => [5, [nil, [6], nil], [nil, [5], nil]] }, set)
    end

    def test_prepare_propagation
        g1, g2 = EventGenerator.new(true), EventGenerator.new(true)
        ev = Event.new(g2, 0, nil)

        step = [nil, [1], nil, nil, [4], nil]
        source_events, source_generators, context = execution_engine.prepare_propagation(nil, false, step)
        assert_equal(Set.new, source_events)
        assert_equal(Set.new, source_generators)
        assert_equal([1, 4], context)

        step = [nil, [], nil, nil, [4], nil]
        source_events, source_generators, context = execution_engine.prepare_propagation(nil, false, step)
        assert_equal(Set.new, source_events)
        assert_equal(Set.new, source_generators)
        assert_equal([4], context)

        step = [g1, [], nil, ev, [], nil]
        source_events, source_generators, context = execution_engine.prepare_propagation(nil, false, step)
        assert_equal([g1, g2].to_set, source_generators)
        assert_equal([ev].to_set, source_events)
        assert_equal([], context)

        step = [g2, [], nil, ev, [], nil]
        source_events, source_generators, context = execution_engine.prepare_propagation(nil, false, step)
        assert_equal([g2].to_set, source_generators)
        assert_equal([ev].to_set, source_events)
        assert_equal([], context)
    end

    def test_next_step
        # For the test to be valid, we need +pending+ to have a deterministic ordering
        # Fix that here
        e1, e2, e3 = EventGenerator.new(true), EventGenerator.new(true), EventGenerator.new(true)
        plan.add [e1, e2, e3]

        pending = []
        def pending.each_key
            each { |(k, _)| yield(k) }
        end

        def pending.delete(ev)
            value = find { |(k, _)| k == ev }.last
            delete_if { |(k, _)| k == ev }
            value
        end

        # If there is no precedence, the order is determined by
        # forwarding/signalling and/or step_id
        pending.clear
        pending << [e1, [0, [], [flexmock]]] << [e2, [1, [flexmock], []]]
        assert_equal(e2, execution_engine.next_event(pending).first)
        pending.clear
        pending << [e1, [1, [flexmock], []]] << [e2, [0, [flexmock], []]]
        assert_equal(e2, execution_engine.next_event(pending).first)

        # If there *is* a precedence relation, we must follow it
        pending.clear
        pending << [e1, [0, [flexmock], []]] << [e2, [1, [flexmock], []]]

        e1.add_precedence e2
        assert_equal(e1, execution_engine.next_event(pending).first)
        e1.remove_precedence e2
        e2.add_precedence e1
        assert_equal(e2, execution_engine.next_event(pending).first)
    end

    def test_delayed_signal
        Timecop.freeze(Time.now)

        plan.add_mission_task(t = Tasks::Simple.new)
        e = EventGenerator.new(true)
        t.start_event.signals e, delay: 0.1
        expect_execution { t.start! }
            .to { have_running t }

        assert !e.emitted?
        expect_execution { Timecop.freeze(Time.now + 0.2) }
            .to { emit e }
    end

    def test_delay_with_unreachability
        time_proxy = flexmock(Time)
        current_time = Time.now + 5
        time_proxy.should_receive(:now).and_return { current_time }

        source, sink0, sink1 = prepare_plan permanent: 3, model: Tasks::Simple
        source.start_event.signals sink0.start_event, delay: 0.1
        source.start_event.signals sink1.start_event, delay: 0.1
        expect_execution do
            source.start!
        end.to do
            not_emit sink0.start_event, sink1.start_event
        end

        expect_execution do
            plan.unmark_permanent_task sink1
            plan.remove_task(sink0)
            sink1.failed_to_start!("test")
        end.to do
            become_unreachable sink0.start_event,
                               sink1.start_event
        end
        refute(
            execution_engine.delayed_events
            .find { |_, _, _, target, _| target == sink0.start_event }
        )
        refute(
            execution_engine.delayed_events
            .find { |_, _, _, target, _| target == sink1.start_event }
        )
    end

    def test_duplicate_signals
        plan.add_mission_task(t = Tasks::Simple.new)

        FlexMock.use do |mock|
            t.start_event.on   { |event| t.success_event.emit(*event.context) }
            t.start_event.on   { |event| t.success_event.emit(*event.context) }

            t.success_event.on { |event| mock.success(event.context) }
            t.stop_event.on    { |event| mock.stop(event.context) }
            mock.should_receive(:success).with([42, 42]).once.ordered
            mock.should_receive(:stop).with([42, 42]).once.ordered
            execute { t.start!(42) }
        end
    end

    def test_default_task_ordering
        a = Tasks::Simple.new_submodel do
            event :intermediate
        end.new(id: "a")

        plan.add_mission_task(a)
        a.depends_on(b = Tasks::Simple.new(id: "b"))

        b.success_event.forward_to a.intermediate_event
        b.success_event.forward_to a.success_event

        FlexMock.use do |mock|
            b.success_event.on { |ev| mock.child_success }
            a.intermediate_event.on { |ev| mock.parent_intermediate }
            a.success_event.on { |ev| mock.parent_success }
            mock.should_receive(:child_success).once.ordered
            mock.should_receive(:parent_intermediate).once.ordered
            mock.should_receive(:parent_success).once.ordered
            execute do
                a.start!
                b.start!
                b.success!
            end
        end
    end

    def test_process_events_diamond_structure
        a = Tasks::Simple.new_submodel do
            event :child_success
            event :child_stop
            forward child_success: :child_stop
        end.new(id: "a")

        plan.add_mission_task(a)
        a.depends_on(b = Tasks::Simple.new(id: "b"))

        b.success_event.forward_to a.child_success_event
        b.stop_event.forward_to a.child_stop_event

        FlexMock.use do |mock|
            a.child_stop_event.on { |ev| mock.stopped }
            mock.should_receive(:stopped).once.ordered
            execute do
                a.start!
                b.start!
                b.success!
            end
        end
    end

    def test_signal_forward
        forward = EventGenerator.new(true)
        signal  = EventGenerator.new(true)
        plan.add [forward, signal]

        FlexMock.use do |mock|
            sink = EventGenerator.new do |context|
                mock.command_called(context)
                sink.emit(42)
            end
            sink.on { |event| mock.handler_called(event.context) }

            forward.forward_to sink
            signal.signals sink

            seeds = execution_engine.gather_propagation do
                forward.call(24)
                signal.call(42)
            end
            mock.should_receive(:command_called).with([42]).once.ordered
            mock.should_receive(:handler_called).with([42, 24]).once.ordered
            execution_engine.event_propagation_phase(seeds, ExecutionEngine::PropagationInfo.new)
        end
    end

    def test_every
        Timecop.freeze(base_time = Time.now)

        # Check that every(cycle_length) works fine
        samples = []
        handler_id = execution_engine.every(0.1) do
            samples << execution_engine.cycle_start
        end

        execute_one_cycle
        Timecop.freeze(base_time + 0.12)
        execute_one_cycle
        execute_one_cycle
        Timecop.freeze(base_time + 0.22)
        execute_one_cycle
        execute_one_cycle
        execution_engine.remove_periodic_handler(handler_id)
        execute_one_cycle
        execute_one_cycle

        expected_samples = [base_time, base_time + 0.12, base_time + 0.22]
        assert_equal expected_samples, samples, "expected #{expected_samples.map { |t| Roby.format_time(t) }}, got #{samples.map { |t| Roby.format_time(t) }}"
    end

    class SpecificException < RuntimeError; end

    def apply_check_structure(&block)
        Plan.structure_checks.clear
        Plan.structure_checks << lambda(&block)
        execute_one_cycle
    ensure
        Plan.structure_checks.clear
    end

    def test_inside_outside_control
        # First, no control thread
        assert(execution_engine.inside_control?)
        assert(!execution_engine.outside_control?)

        t = Thread.new do
            assert(!execution_engine.inside_control?)
            assert(execution_engine.outside_control?)
        end
        t.value
    end

    def test_execute
        FlexMock.use do |mock|
            mock.should_receive(:thread_before).once.ordered
            mock.should_receive(:main_before).once.ordered
            mock.should_receive(:execute).once.ordered.with(Thread.current).and_return(42)
            mock.should_receive(:main_after).once.ordered(:finish)
            mock.should_receive(:thread_after).once.ordered(:finish)

            returned_value = nil
            t = Thread.new do
                mock.thread_before
                returned_value = execution_engine.execute do
                    mock.execute(Thread.current)
                end
                mock.thread_after
            end

            # Wait for the thread to block
            until t.stop?; sleep(0.01) end
            mock.main_before
            assert(t.alive?)
            # We use execution_engine.process_events as we are making the execution_engine
            # believe that it is running while it is not
            execution_engine.process_events
            mock.main_after
            t.join

            assert_equal(42, returned_value)
        end
    end

    def test_execute_error
        assert(!execution_engine.quitting?)

        returned_value = nil
        t = Thread.new do
            returned_value = begin
                                 execution_engine.execute do
                                     raise ArgumentError
                                 end
                             rescue ArgumentError => e
                                 e
                             end
        end

        # Wait for the thread to block
        until t.stop?; sleep(0.01) end
        assert(t.alive?)
        # We use execution_engine.process_events as we are making the execution_engine
        # believe that it is running while it is not
        execution_engine.process_events
        t.join

        assert_kind_of(ArgumentError, returned_value)
        assert(!execution_engine.quitting?)
    end

    def test_stats
        time_events = %i[actual_start events structure_check exception_propagation exception_fatal garbage_collect application_errors ruby_gc sleep end]
        10.times do
            FlexMock.use(execution_engine) do |mock|
                mock.should_receive(:cycle_end).and_return do |stats|
                    timepoints = stats.slice(*time_events)
                    assert(timepoints.all? { |name, d| d > 0 })

                    sorted_by_time = timepoints.sort_by { |name, d| d }
                    sorted_by_name = timepoints.sort_by { |name, d| time_events.index(name) }
                    sorted_by_time.each_with_index do |(_name, d), i|
                        assert(sorted_by_name[i][1] == d)
                    end
                end
                execution_engine.process_events
            end
        end
    end

    def assert_finalizes(plan, finalized, unneeded = nil)
        FlexMock.use(plan) do |mock|
            if finalized.empty?
                mock.should_receive(:finalized_task).never
                mock.should_receive(:finalized_event).never
            else
                finalized.each do |obj|
                    if obj.respond_to?(:to_task)
                        mock.should_receive(:finalized_task).with(obj).once
                    else
                        mock.should_receive(:finalized_event).with(obj).once
                    end
                end
            end

            execute do
                yield if block_given?
            end

            execute { execution_engine.garbage_collect }
            execute { execution_engine.garbage_collect }
            if unneeded
                assert_equal(unneeded.to_set, plan.unneeded_tasks.to_set)
            end
        end
    end

    def test_garbage_collect_tasks
        klass = Task.new_submodel do
            attr_accessor :delays

            event(:start, command: true)
            event(:stop) do |context|
                if delays
                    return
                else
                    stop_event.emit
                end
            end
        end

        (m1, m2, m3), (t1, t2, t3, t4, t5, p1) =
            prepare_plan missions: 3, add: 6, model: klass
        m1.depends_on t1
        t1.depends_on t2
        m2.depends_on t1
        m3.depends_on t2
        m3.planned_by p1
        p1.depends_on t3
        t4.depends_on t5

        plan.add_permanent_task(t4)

        assert_finalizes(plan, [])
        assert_finalizes(plan, [m1]) { plan.unmark_mission_task(m1) }
        assert_finalizes(plan, [m2, t1]) do
            m2.start!
            plan.unmark_mission_task(m2)
        end

        assert_finalizes(plan, [], [m3, p1, t3, t2]) do
            m3.delays = true
            m3.start!
            plan.unmark_mission_task(m3)
        end
        assert(m3.event(:stop).pending?)
        assert_finalizes(plan, [m3, p1, t3, t2]) do
            m3.stop_event.emit
        end
    ensure
        t5.stop_event.emit if t5.delays && t5.running?
    end

    def test_force_garbage_collect_tasks
        t1 = Task.new_submodel do
            event(:stop) { |context| }
        end.new
        t2 = Task.new
        t1.depends_on t2

        plan.add_mission_task(t1)
        execute { t1.start! }
        assert_finalizes(plan, []) do
            execution_engine.garbage_collect([t1])
        end
        assert(t1.event(:stop).pending?)

        assert_finalizes(plan, [t1, t2]) do
            # This stops the mission, which will be automatically discarded
            t1.stop_event.emit
        end
    end

    # Test a setup where there is both pending tasks and running tasks. This
    # checks that #stop! is called on all the involved tasks. This tracks
    # problems related to bindings in the implementation of #garbage_collect:
    # the killed task bound to the Roby.once block must remain the same.

    def test_garbage_collect_events
        t  = Tasks::Simple.new
        e1 = EventGenerator.new(true)

        plan.add_mission_task(t)
        plan.add(e1)
        assert_equal([e1], plan.unneeded_events.to_a)
        t.event(:start).signals e1
        assert_equal([], plan.unneeded_events.to_a)

        e2 = EventGenerator.new(true)
        plan.add(e2)
        assert_equal([e2], plan.unneeded_events.to_a)
        e1.forward_to e2
        assert_equal([], plan.unneeded_events.to_a)

        execute { plan.remove_task(t) }
        assert_equal([e1, e2].to_set, plan.unneeded_events)

        plan.add_permanent_event(e1)
        assert_equal([], plan.unneeded_events.to_a)
        plan.unmark_permanent_event(e1)
        assert_equal([e1, e2].to_set, plan.unneeded_events)
        plan.add_permanent_event(e2)
        assert_equal([], plan.unneeded_events.to_a)
        plan.unmark_permanent_event(e2)
        assert_equal([e1, e2].to_set, plan.unneeded_events)
    end

    Roby::TaskStructure.relation :WeakTest, weak: true

    def test_garbage_collect_weak_relations
        planning, planned, influencing = prepare_plan discover: 3, model: Tasks::Simple

        # Create a cycle with a weak relation
        planned.planned_by planning
        influencing.depends_on planned
        planning.add_weak_test influencing

        expect_execution do
            planned.start!
            planning.start!
            influencing.start!
        end.garbage_collect(true).to { achieve { plan.tasks.empty? } }
    end

    def test_forward_signal_ordering
        100.times do
            stop_called = false
            source = Tasks::Simple.new(id: "source")
            target = Tasks::Simple.new_submodel do
                event :start do |context|
                    unless stop_called
                        raise ArgumentError, "ordering failed"
                    end

                    start_event.emit
                end
            end.new(id: "target")
            plan.add(source)
            plan.add(target)

            source.success_event.signals target.start_event
            source.stop_event.on do |ev|
                stop_called = true
            end
            expect_execution do
                source.start!
                source.success_event.emit
            end.to { achieve { target.running? } }
            execute { target.stop! }
        end
    end

    def test_garbage_collection_calls_are_propagated_first_while_quitting
        obj = Class.new do
            def stopped?
                @stop
            end

            def stop
                @stop = true
            end
        end.new
        flexmock(obj).should_receive(:stop).once
            .pass_thru

        task_model = Class.new(Roby::Task) do
            argument :obj

            event :start, controlable: true
            event :stop do |_|
                obj.stop
                stop_event.emit
            end
        end
        plan.add(task = task_model.new(obj: obj))
        execute { task.start! }
        plan.execution_engine.at_cycle_begin do
            unless obj.stopped?
                obj.stop
            end
        end
        plan.execution_engine.quit
        expect_execution.to { achieve { !task.running? } }
    end
end
