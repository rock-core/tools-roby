# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Test
        describe ExecutionExpectations do
            describe "#execute" do
                it "handles a non-executable plan" do
                    plan = Plan.new
                    plan.add(task = Roby::Task.new)
                    execute(plan: plan) { plan.remove_task(task) }
                    refute plan.has_task?(task)
                end
            end

            describe "#expect_execution" do
                it "executes the first block in propagation context" do
                    plan.add(task = Roby::Tasks::Simple.new)
                    expect_execution { task.start! }.to {}
                    assert task.running?
                end

                it "executes the first block after the to ... block" do
                    plan.add(Roby::Tasks::Simple.new)
                    executed, to_executed, was_expect_executed = false
                    expect_execution { executed = true }
                        .to do
                            to_executed = true
                            was_expect_executed = executed
                        end
                    assert to_executed
                    refute was_expect_executed
                end

                it "returns a plain value returned by the to { } block" do
                    ret = flexmock
                    assert_equal(ret, expect_execution.to { ret })
                end

                it "calls #return_value on the block's return value" do
                    ret = flexmock(return_object: 10)
                    assert_equal(10, expect_execution.to { ret })
                end

                it "calls #return_value on the the elements of an array" do
                    ret1 = flexmock(return_object: 10)
                    ret2 = flexmock(return_object: 20)
                    assert_equal([10, 20, 42], expect_execution.to { [ret1, ret2, 42] })
                end

                it "processes the value returned by #return_object through #filter_result" do
                    ret1 = flexmock(return_object: 10)
                    ret1.should_receive(:filter_result).with(10).and_return(15).once
                    assert_equal([15, 42], expect_execution.to { [ret1, 42] })
                end
            end

            describe "#verify" do
                attr_reader :expectations

                before do
                    @expectations = ExecutionExpectations.new(self, plan)
                    flexmock(@expectations)
                    flexmock(execution_engine)
                end

                describe "propagation setup" do
                    it "disables an enabled scheduler if the scheduler is explicitely set to false" do
                        expectations.scheduler false
                        execution_engine.scheduler.enabled = true
                        execution_engine
                            .should_receive(:process_events)
                            .pass_thru do |ret|
                                refute execution_engine.scheduler.enabled?
                                ret
                            end
                        expectations.verify
                    end
                    it "restores an enabled scheduler after the verification" do
                        expectations.scheduler false
                        execution_engine.scheduler.enabled = true
                        execution_engine.should_receive(:process_events).pass_thru
                        expectations.verify
                        assert execution_engine.scheduler.enabled?
                    end
                    it "enables a disabled scheduler if the scheduler is explicitely set to false" do
                        expectations.scheduler true
                        execution_engine.scheduler.enabled = false
                        execution_engine.should_receive(:process_events)
                            .pass_thru { |ret| assert execution_engine.scheduler.enabled?; ret }
                        expectations.verify
                    end
                    it "restores an enabled scheduler after the verification" do
                        expectations.scheduler true
                        execution_engine.scheduler.enabled = false
                        execution_engine.should_receive(:process_events).pass_thru
                        expectations.verify
                        refute execution_engine.scheduler.enabled?
                    end
                    it "calls process_events with garbage_collect_pass: true if #garbage_collect is true" do
                        expectations.garbage_collect true
                        execution_engine.should_receive(:process_events)
                            .with(hsh(garbage_collect_pass: true))
                            .pass_thru
                    end
                    it "calls process_events with garbage_collect_pass: false if #garbage_collect is false" do
                        expectations.garbage_collect false
                        execution_engine.should_receive(:process_events)
                            .with(hsh(garbage_collect_pass: false))
                            .pass_thru
                    end
                end

                describe "cycle_end" do
                    attr_reader :recorder

                    before do
                        @handler_ids = []
                        @recorder = flexmock
                    end
                    after do
                        @handler_ids.each do |id|
                            execution_engine.remove_at_cycle_end(id)
                        end
                    end

                    def at_cycle_end(&block)
                        @handler_ids << execution_engine.at_cycle_end(&block)
                    end

                    it "executes cycle_end handlers" do
                        recorder.should_receive(:called).once
                        at_cycle_end { recorder.called }
                        execute_one_cycle
                    end

                    it "gets exceptions from cycle_end as framework errors" do
                        exception_m = Class.new(RuntimeError)
                        at_cycle_end { raise exception_m }
                        expect_execution.to { have_framework_error_matching exception_m }
                    end
                end

                describe "promise handling" do
                    it "handles waiting work that interacts with the execution thread" do
                        executed = false
                        thread = Thread.new do
                            execution_engine.execute { executed = true }
                        end
                        expect_execution.to { achieve { executed } }
                        thread.join
                    end
                end

                describe "exit conditions" do
                    describe "with join_all_waiting_work set" do
                        before do
                            expectations.join_all_waiting_work true
                        end

                        it "quits the loop if there are no asynchronous jobs pending" do
                            expectations.verify
                        end

                        it "continues looping if there is waiting work" do
                            execution_engine.should_receive(:has_waiting_work?)
                                .and_return(true, false)
                            execution_engine.should_receive(:process_events).twice
                                .and_return(ExecutionEngine::PropagationInfo.new)
                            expectations.verify
                        end

                        it "executes the block only once" do
                            execution_engine.should_receive(:has_waiting_work?)
                                .and_return(true, false)
                            recorder = flexmock
                            recorder.should_receive(:called).with(true).once
                            expectations.verify { recorder.called(execution_engine.in_propagation_context?) }
                        end

                        it "raises if there are unachievable expectations" do
                            execution_engine.should_receive(:has_waiting_work?)
                                            .and_return(true)
                            expectations.add_expectation(
                                flexmock(
                                    format_unachievable_explanation: "",
                                    explain_unachievable: "", update_match: false,
                                    unachievable?: true
                                )
                            )
                            assert_raises(ExecutionExpectations::Unmet) do
                                expectations.timeout 0
                                expectations.verify {}
                            end
                        end
                    end

                    describe "with join_all_waiting_work unset" do
                        before do
                            expectations.join_all_waiting_work false
                            execution_engine.should_receive(:has_waiting_work?)
                                            .and_return(true)
                        end

                        it "executes the loop only once" do
                            execution_engine.should_receive(:process_events).once
                                .pass_thru
                            expectations.verify
                        end

                        it "executes the block once in propagation context" do
                            recorder = flexmock
                            recorder.should_receive(:called).with(true).once
                            expectations.verify do
                                recorder.called(execution_engine.in_propagation_context?)
                            end
                        end

                        it "raises if there are unachievable expectations" do
                            expectations.add_expectation(
                                flexmock(
                                    format_unachievable_explanation: "",
                                    explain_unachievable: "", update_match: false,
                                    unachievable?: true
                                )
                            )
                            assert_raises(ExecutionExpectations::Unmet) do
                                expectations.timeout 0
                                expectations.verify {}
                            end
                        end

                        it "raises if there are unmet expectations" do
                            expectations.add_expectation(
                                flexmock(update_match: false, unachievable?: false)
                            )
                            assert_raises(ExecutionExpectations::Unmet) do
                                expectations.timeout 0
                                expectations.verify {}
                            end
                        end
                    end
                end
            end

            describe "#unexpected_error?" do
                before do
                    @predicate = flexmock(ExecutionExpectations::Expectation.new([]))
                    @harness = ExecutionExpectations.new(self, plan)
                    @harness.add_expectation @predicate

                    @exception = Exception.new
                    @localized_error = CodeError.new(@exception, Roby::Task.new)
                    @execution_exception = ExecutionException.new(@localized_error)
                end

                describe "from an ExecutionException" do
                    it "returns true if none of the predicates match" do
                        @predicate.should_receive(:relates_to_error?)
                        assert @harness.unexpected_error?(@execution_exception)
                    end

                    it "tests against the execution exception error" do
                        @predicate.should_receive(:relates_to_error?)
                                .with(@execution_exception).once.and_return(true)
                        @predicate.should_receive(:relates_to_error?)
                        refute @harness.unexpected_error?(@execution_exception)
                    end

                    it "tests against the original error" do
                        @predicate.should_receive(:relates_to_error?)
                                .with(@localized_error).once.and_return(true)
                        @predicate.should_receive(:relates_to_error?)
                        refute @harness.unexpected_error?(@execution_exception)
                    end

                    it "tests against the original error's own original errors" do
                        @predicate.should_receive(:relates_to_error?)
                                .with(@exception).once.and_return(true)
                        @predicate.should_receive(:relates_to_error?)
                        refute @harness.unexpected_error?(@execution_exception)
                    end
                end

                describe "from a Roby::ExceptionBase" do
                    it "returns true if none of the predicates match" do
                        @predicate.should_receive(:relates_to_error?)
                        assert @harness.unexpected_error?(@localized_error)
                    end

                    it "tests against the error itself" do
                        @predicate.should_receive(:relates_to_error?)
                                .with(@localized_error).once.and_return(true)
                        @predicate.should_receive(:relates_to_error?)
                        refute @harness.unexpected_error?(@localized_error)
                    end

                    it "tests against the original error" do
                        @predicate.should_receive(:relates_to_error?)
                                .with(@exception).once.and_return(true)
                        @predicate.should_receive(:relates_to_error?)
                        refute @harness.unexpected_error?(@localized_error)
                    end

                    it "tests against the original error's own original errors" do
                        level2_e = Exception.new
                        flexmock(@exception)
                            .should_receive(:each_original_exception).explicitly
                            .and_yield(level2_e)
                        @predicate.should_receive(:relates_to_error?)
                                .with(level2_e).once.and_return(true)
                        @predicate.should_receive(:relates_to_error?)
                        refute @harness.unexpected_error?(@localized_error)
                    end
                end

                describe "from a plain exceptin" do
                    it "returns true if none of the predicates match" do
                        @predicate.should_receive(:relates_to_error?)
                        assert @harness.unexpected_error?(@exception)
                    end

                    it "tests against the error itself" do
                        @predicate.should_receive(:relates_to_error?)
                                .with(@exception).once.and_return(true)
                        refute @harness.unexpected_error?(@exception)
                    end
                end
            end

            describe "standard expectations" do
                it "implements a generic result filtering" do
                    expectation_class = Class.new(ExecutionExpectations::Expectation) do
                        def return_object
                            10
                        end
                    end

                    expectation = expectation_class.new([]).filter_result_with { |a| a * 2 }
                    result = expect_execution.to { add_expectation(expectation) }
                    assert_equal 20, result

                    expectation = expectation_class.new([])
                                  .filter_result_with { |a| a * 2 }
                                  .filter_result_with { |a| a - 5 }
                    result = expect_execution.to { add_expectation(expectation) }
                    assert_equal 15, result
                end

                describe "#emits a generator instance" do
                    it "validates when the event is emitted" do
                        plan.add(generator = EventGenerator.new)
                        expect_execution { generator.emit }
                            .to { emit generator }
                    end
                    it "fails if the event is not emitted" do
                        plan.add(generator = EventGenerator.new)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution
                                .timeout(0)
                                .to { emit generator }
                        end
                        assert_equal(
                            "1 unmet expectations\n#{generator} "\
                            "should be emitted", e.message
                        )
                    end
                    it "fails if the event becomes unreachable" do
                        plan.add(generator = EventGenerator.new)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { generator.unreachable! }
                                .timeout(0)
                                .to { emit generator }
                        end
                        assert_equal(
                            "1 unmet expectations\n#{generator} should be emitted",
                            e.message
                        )
                    end
                    it "reports unreachability reason if there is one" do
                        plan.add(generator = EventGenerator.new)
                        plan.add(cause = EventGenerator.new)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { generator.unreachable!(cause) }
                                .timeout(0).to { emit generator }
                        end
                        assert_equal(
                            "1 unmet expectations\n#{generator} "\
                            "should be emitted, but it did not because of "\
                            "#{PP.pp(cause, ''.dup, 0).chomp}",
                            e.message
                        )
                    end
                    it "validates if the event's emission caused exceptions" do
                        plan.add(generator = EventGenerator.new)
                        expect_execution do
                            generator.emit
                            generator.on do |ev|
                                execution_engine.add_error(LocalizedError.new(ev))
                            end
                        end.to { emit generator }
                    end
                    it "ignores non-LocalizedError exceptions" do
                        plan.add(generator = EventGenerator.new)
                        assert_predicate_ignores_framework_error(
                            execute: proc { generator.emit },
                            predicates: proc { emit generator }
                        )
                    end
                    it "handles a toplevel task error caused by the event" do
                        execution_agent_m = Tasks::Simple.new_submodel do
                            event :ready
                        end
                        task_m = Task.new_submodel do
                            event :start do |context|
                            end
                        end
                        plan.add_mission_task(task = task_m.new)
                        plan.add(agent = execution_agent_m.new)
                        task.executed_by agent

                        execute do
                            agent.start!
                            agent.ready_event.emit
                            task.start!
                        end

                        expect_execution { agent.stop! }
                            .to do
                                fail_to_start task
                                emit agent.stop_event
                            end
                    end

                    it "does not relate to a handler error" do
                        task_m = Task.new_submodel do
                            event(:start, controlable: true) { |_| start_event.emit }
                        end
                        plan.add_mission_task(task = task_m.new)
                        task.stop_event.on { raise ArgumentError }

                        execute do
                            task.start!
                        end

                        e = assert_raises(ExecutionExpectations::UnexpectedErrors) do
                            expect_execution { task.stop_event.emit }
                                .to { emit task.stop_event }
                        end

                        errors = e.each_execution_exception.to_a
                        assert_kind_of EventHandlerError, errors[0].exception
                        assert_kind_of ArgumentError,
                                       errors[0].exception.each_original_exception.first
                        assert_kind_of MissionFailedError, errors[1].exception
                    end
                end

                describe "#emit a task event query" do
                    attr_reader :task_m

                    before do
                        @task_m = Roby::Tasks::Simple.new_submodel
                    end
                    it "validates when the event is emitted" do
                        task = nil
                        result = expect_execution do
                            plan.add(task = task_m.new)
                            task.start!
                        end.to { emit find_tasks(task_m).start_event }
                        assert_equal [task.start_event.last], result
                    end
                    it "fails if no matching events are added" do
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution
                                .timeout(0)
                                .to { emit find_tasks(task_m).start_event }
                        end
                        assert_equal(
                            "1 unmet expectations\nat least one event matching "\
                            "#{task_m}.start should be emitted",
                            e.message
                        )
                    end
                    it "fails if matching events are not emitted" do
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution do
                                plan.add(task_m.new)
                            end.timeout(0).to { emit find_tasks(task_m).start_event }
                        end
                        assert_equal(
                            "1 unmet expectations\nat least one event matching "\
                            "#{task_m}.start should be emitted",
                            e.message
                        )
                    end
                    it "validates if the event's emission caused exceptions" do
                        expect_execution do
                            plan.add(task = task_m.new)
                            task.start_event.on do |ev|
                                execution_engine.add_error(LocalizedError.new(ev))
                            end
                            task.start!
                        end.to { emit find_tasks(task_m).start_event }
                    end
                    it "ignores non-LocalizedError exceptions" do
                        plan.add(task = task_m.new)
                        assert_predicate_ignores_framework_error(
                            execute: proc { task.start! },
                            predicates: proc { emit find_tasks(task_m).start_event }
                        )
                    end
                    it "handles a toplevel task error caused by the event" do
                        execution_agent_m = Tasks::Simple.new_submodel { event :ready }
                        task_m = Task.new_submodel do
                            event(:start) { |_| }
                        end
                        plan.add_mission_task(task = task_m.new)
                        plan.add(agent = execution_agent_m.new)
                        task.executed_by agent

                        execute do
                            agent.start!
                            agent.ready_event.emit
                            task.start!
                        end

                        expect_execution { agent.stop! }
                            .to do
                                fail_to_start task
                                emit execution_agent_m.match.stop_event
                            end
                    end
                    it "does not relate to a handler error" do
                        task_m = Task.new_submodel do
                            event(:start, controlable: true) { |_| start_event.emit }
                        end
                        plan.add_mission_task(task = task_m.new)
                        task.stop_event.on { raise ArgumentError }

                        execute do
                            task.start!
                        end

                        e = assert_raises(ExecutionExpectations::UnexpectedErrors) do
                            expect_execution { task.stop_event.emit }
                                .to { emit task_m.match.stop_event }
                        end

                        errors = e.each_execution_exception.to_a
                        assert_kind_of EventHandlerError, errors[0].exception
                        assert_kind_of ArgumentError,
                                       errors[0].exception.each_original_exception.first
                        assert_kind_of MissionFailedError, errors[1].exception
                    end
                end

                describe "#not_emit a generator instance" do
                    it "validates when the event is not emitted" do
                        plan.add(generator = EventGenerator.new)
                        expect_execution.to { not_emit generator }
                    end
                    it "fails if the event is emitted within the first cycle" do
                        plan.add(generator = EventGenerator.new)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { generator.emit }
                                .to { not_emit generator }
                        end
                        assert e.message.start_with?(
                            "1 unmet expectations\n#{generator} "\
                            "should not be emitted, but it was:"
                        )
                    end
                    it "passes by default after the first cycle" do
                        plan.add(generator = EventGenerator.new)
                        count = 0
                        expect_execution
                            .poll { count += 1; generator.emit if count == 2 }
                            .to { not_emit generator }
                    end
                    it "may be told given a timespan with the within argument" do
                        plan.add(generator = EventGenerator.new)
                        count = 0
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution
                                .poll { count += 1; generator.emit if count == 3 }
                                .to { not_emit generator, within: 0.1 }
                        end
                    end
                end

                describe "#not_emit a task event query" do
                    attr_reader :task_m

                    before do
                        @task_m = Roby::Tasks::Simple.new_submodel
                    end
                    it "validates when the event is not emitted" do
                        plan.add(task_m.new)
                        expect_execution.to { not_emit find_tasks(task_m).start_event }
                    end
                    it "fails if a matching event is emitted within the first cycle" do
                        plan.add(task = task_m.new)
                        query = plan.find_tasks(task_m).start_event
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { task.start! }
                                .to { not_emit query }
                        end
                        assert e.message.start_with?(
                            "1 unmet expectations\nno events matching #{query} should "\
                            "be emitted, but one was:"
                        ), e.message
                    end
                    it "does not fail by default if it is emitted in the 2nd cycle" do
                        plan.add(task = task_m.new)
                        count = 0
                        expect_execution
                            .poll { count += 1; task.start! if count > 2 }
                            .to { not_emit find_tasks(task_m).start_event }
                    end
                    it "allows to specify a time to wait with the within option" do
                        plan.add(task = task_m.new)
                        count = 0
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution
                                .poll { count += 1; task.start! if count > 2 }
                                .to do
                                    not_emit find_tasks(task_m).start_event, within: 0.1
                                end
                        end
                    end
                end

                describe "#have_error_matching" do
                    it "validates when the exception has been raised" do
                        plan.add(task = Roby::Task.new)
                        exception_comes_from_start =
                            ->(e) { e.exception.failed_generator == task.start_event }
                        matcher = flexmock
                        matcher.should_receive(:exception_matcher).and_return(flexmock)
                        matcher.should_receive(:===)
                               .with(exception_comes_from_start).and_return(true)
                        expect_execution do
                            execution_engine.add_error(
                                LocalizedError.new(task.start_event)
                            )
                        end.to do
                            have_error_matching(
                                flexmock(to_execution_exception_matcher: matcher)
                            )
                        end
                    end
                    it "fails if only non-matching exceptions have been raised" do
                        plan.add(task = Roby::Task.new)
                        failed_in_start =
                            ->(e) { e.exception.failed_generator == task.start_event }
                        matcher = flexmock
                        matcher.should_receive(:exception_matcher).and_return(flexmock)
                        matcher.should_receive(:===)
                               .with(failed_in_start).and_return(false)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution do
                                execution_engine.add_error(
                                    LocalizedError.new(task.start_event)
                                )
                            end.timeout(0).to do
                                have_error_matching LocalizedError
                                have_error_matching(
                                    flexmock(to_execution_exception_matcher: matcher)
                                )
                            end
                        end
                        assert_match(/^1 unmet expectations\nshould have an error matching #{matcher}/m, e.message)
                    end
                    it "fails if no exceptions have been raised" do
                        plan.add(Roby::Task.new)
                        matcher = flexmock
                        matcher.should_receive(:exception_matcher).and_return(flexmock)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution
                                .timeout(0)
                                .to do
                                    have_error_matching(
                                        flexmock(to_execution_exception_matcher: matcher)
                                    )
                                end
                        end
                        assert_match(/^1 unmet expectations\nshould have an error matching #{matcher}/m, e.message)
                    end
                    it "validates even if the exception causes other errors" do
                        plan.add(task = Roby::Task.new)
                        plan.add(other_task = Roby::Task.new)
                        matcher = flexmock
                        matcher.should_receive(:exception_matcher).and_return(flexmock)
                        matcher.should_receive(:===)
                               .with(->(e) { e.exception.failed_generator == task.start_event })
                               .and_return(true)
                        expect_execution do
                            execution_engine.add_error(error = LocalizedError.new(task.start_event))
                            other_error = LocalizedError.new(other_task.start_event)
                            other_error.report_exceptions_from(error)
                        end.to { have_error_matching flexmock(to_execution_exception_matcher: matcher) }
                    end
                    it "relates to a task error that is transformed into an internal_error event" do
                        plan.add(task = Roby::Tasks::Simple.new)
                        expect_execution { execution_engine.add_error(CodeError.new(ArgumentError.new, task)) }
                            .to { have_error_matching CodeError.match.with_origin(task) }
                    end
                    it "ignores non-LocalizedError exceptions" do
                        plan.add(task = Roby::Task.new)
                        assert_predicate_ignores_framework_error(
                            execute: (
                                proc do
                                    execution_engine.add_error(
                                        LocalizedError.new(task.start_event)
                                    )
                                end
                            ),
                            predicates: proc { have_error_matching LocalizedError }
                        )
                    end
                end

                describe "#have_handled_error_matching" do
                    attr_reader :matcher, :error_m

                    before do
                        @error_m = Class.new(LocalizedError)
                        @task_m = Roby::Task.new_submodel
                        @task_m.on_exception(@error_m) { |e| }
                        plan.add(@task = @task_m.new)
                        @matcher = flexmock
                        @matcher.should_receive(:exception_matcher).and_return(flexmock)
                    end

                    it "validates when the exception has been raised and handled" do
                        @matcher.should_receive(:===)
                            .with(->(e) { e.exception.failed_generator == @task.start_event })
                            .and_return(true)
                        expect_execution do
                            execution_engine.add_error(@error_m.new(@task.start_event))
                        end.to { have_handled_error_matching flexmock(to_execution_exception_matcher: matcher) }
                    end
                    it "fails if only non-matching exceptions have been raised" do
                        @matcher.should_receive(:===)
                            .with(->(e) { e.exception.failed_generator == @task.start_event })
                            .and_return(false)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution do
                                execution_engine.add_error(@error_m.new(@task.start_event))
                            end.timeout(0)
                            .to { have_handled_error_matching flexmock(to_execution_exception_matcher: matcher) }
                        end
                        assert_match(/^1 unmet expectations\nshould have handled an error matching #{matcher}/m, e.message)
                    end
                    it "fails if no exceptions have been raised" do
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution
                                .timeout(0)
                                .to { have_handled_error_matching flexmock(to_execution_exception_matcher: matcher) }
                        end
                        assert_match(/^1 unmet expectations\nshould have handled an error matching #{matcher}/m, e.message)
                    end
                    it "validates even if the exception causes other errors" do
                        plan.add(other_task = Roby::Task.new)
                        @matcher.should_receive(:===)
                            .with(->(e) { e.exception.failed_generator == @task.start_event })
                            .and_return(true)
                        expect_execution do
                            execution_engine.add_error(error = @error_m.new(@task.start_event))
                            other_error = @error_m.new(other_task.start_event)
                            other_error.report_exceptions_from(error)
                        end.to { have_handled_error_matching flexmock(to_execution_exception_matcher: matcher) }
                    end
                    it "relates to a task error that is transformed into an internal_error event" do
                        plan.add(task = Roby::Tasks::Simple.new)
                        expect_execution { execution_engine.add_error(CodeError.new(ArgumentError.new, task)) }
                            .to { have_error_matching CodeError.match.with_origin(task) }
                    end
                    it "ignores non-LocalizedError exceptions" do
                        error_m = @error_m
                        task_m = Roby::Tasks::Simple.new_submodel
                        task_m.on_exception(error_m) { |*| }
                        plan.add(task = task_m.new)
                        assert_predicate_ignores_framework_error(
                            execute: (
                                proc do
                                    execution_engine.add_error(
                                        error_m.new(task.start_event)
                                    )
                                end
                            ),
                            predicates: proc { have_handled_error_matching error_m }
                        )
                    end
                end

                describe "#have_internal_error" do
                    attr_reader :error_m, :task_m

                    before do
                        @task_m = Task.new_submodel
                        @task_m.terminates
                        @error_m = Class.new(ArgumentError)
                    end

                    describe "when the task does raise an internal error" do
                        attr_reader :task

                        before do
                            error_m = @error_m
                            task_m.poll { raise error_m }
                            plan.add(@task = task_m.new)
                        end
                        it "matches the exception" do
                            expect_execution { task.start! }
                                .to { have_internal_error task, error_m }
                        end
                        it "does not match if the exception does not fit the matcher object" do
                            other_error_m = Class.new(RuntimeError)
                            assert_raises(ExecutionExpectations::Unmet) do
                                expect_execution { task.start! }.timeout(0)
                                    .to do
                                        have_internal_error task, error_m
                                        have_internal_error task, other_error_m
                                    end
                            end
                        end
                    end

                    it "does not match if the task raises nothing" do
                        plan.add(task = @task_m.new)
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution.timeout(0)
                                .to { have_internal_error task, error_m }
                        end
                    end
                    it "does not match a plain internal_error_event emission" do
                        plan.add(task = @task_m.new)
                        execute { task.start! }
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { task.internal_error_event.emit }.timeout(0)
                                .to { have_internal_error task, error_m }
                        end
                    end
                    it "ignores non-LocalizedError exceptions" do
                        error_m = @error_m
                        task_m.poll { raise error_m }
                        plan.add(task = task_m.new)
                        assert_predicate_ignores_framework_error(
                            execute: proc { task.start! },
                            predicates: proc { have_internal_error task, error_m }
                        )
                    end
                end

                describe "#fail_to_start" do
                    attr_reader :task, :error_m

                    before do
                        task_m = Task.new_submodel
                        task_m.terminates
                        plan.add(@task = task_m.new)
                        @error_m = Class.new(ArgumentError)
                    end
                    it "matches a task that fails to start" do
                        expect_execution { task.failed_to_start!(CodeError.new(error_m.new, task)) }
                            .to { fail_to_start task }
                    end
                    it "matches the failure reason" do
                        expect_execution { task.failed_to_start!(CodeError.new(error_m.new, task)) }
                            .to { fail_to_start task, reason: error_m }
                    end
                    it "returns the failure reason" do
                        ret = expect_execution { task.failed_to_start!(CodeError.new(error_m.new, task)) }
                            .to { fail_to_start task, reason: error_m }
                        assert_equal task.failure_reason, ret
                    end
                    it "does not match if the given reason matcher does not match the failure reason" do
                        other_error_m = Class.new(RuntimeError)
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { task.failed_to_start!(CodeError.new(error_m.new, task)) }
                                .to do
                                    fail_to_start task, reason: other_error_m
                                    fail_to_start task, reason: error_m
                                end
                        end
                    end
                    it "is related to the original failure reason" do
                        expect_execution do
                            original_e = CodeError.new(error_m.new, task)
                            execution_engine.add_error(original_e)
                            task.failed_to_start!(original_e)
                        end.to { fail_to_start task, reason: error_m }
                    end
                    it "relates to the matched failure's reason if no reason matcher was given" do
                        expect_execution do
                            original_e = CodeError.new(error_m.new, task)
                            execution_engine.add_error(original_e)
                            task.failed_to_start!(original_e)
                        end.to { fail_to_start task }
                    end
                    it "relates to exceptions caused by the matched failure's reason if no reason matcher was given" do
                        expect_execution do
                            original_e = CodeError.new(error_m.new, task)
                            execution_engine.add_error(
                                MissionFailedError.new(task, original_e)
                            )
                            task.failed_to_start!(original_e)
                        end.to { fail_to_start task }
                    end
                    it "ignores non-LocalizedError exceptions" do
                        assert_predicate_ignores_framework_error(
                            execute: proc { task.failed_to_start!(Exception.new) },
                            predicates: proc { fail_to_start task }
                        )
                    end
                end

                describe "#have_framework_error_matching" do
                    attr_reader :error_m

                    before do
                        @error_m = Class.new(RuntimeError)
                    end
                    it "matches a framework error" do
                        expect_execution { execution_engine.add_framework_error(error_m.new, "test") }
                            .to { have_framework_error_matching error_m }
                    end
                    it "does not match an unrelated framework error" do
                        other_error_m = Class.new(RuntimeError)
                        assert_raises(ExecutionExpectations::UnexpectedErrors) do
                            expect_execution { execution_engine.add_framework_error(error_m.new, "test") }
                                .timeout(0)
                                .to do
                                    have_framework_error_matching other_error_m
                                end
                        end
                    end
                    it "does not match if no framework errors happened" do
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution
                                .timeout(0)
                                .to do
                                    have_framework_error_matching error_m
                                end
                        end
                    end
                end

                describe "#promise_finishes" do
                    it "waits until the promise finishes" do
                        promise = execution_engine.promise.then {}.on_success {}.then {}
                        expect_execution { promise.execute }
                            .to { finish_promise promise }
                        assert promise.complete?
                    end
                    it "is successful even if the promise fails" do
                        promise =
                            execution_engine
                            .promise.then {}.on_success {}
                            .then { raise ArgumentError }.on_error {}
                        expect_execution { promise.execute }
                            .to { finish_promise promise }
                        assert promise.complete?
                    end
                    it "ignores non-LocalizedError exceptions" do
                        promise = execution_engine.promise.then {}.on_success {}.then {}
                        assert_predicate_ignores_framework_error(
                            execute: proc { promise.execute },
                            predicates: proc { finish_promise promise }
                        )
                    end
                end

                describe "#maintain" do
                    it "succeeds if the block returns true during the whole duration" do
                        expect_execution
                            .to { maintain(at_least_during: 0.2) { true } }
                    end
                    it "fails if the block returns false at least one time during the whole duration" do
                        flag = false
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution
                                .to { maintain(at_least_during: 0.2) { flag = !flag } }
                        end
                    end
                    it "evaluates the block for at_least_during seconds" do
                        Timecop.freeze(base_time = Time.now)
                        expect_execution.to do
                            maintain(at_least_during: 1) { Timecop.freeze(Time.now + 0.1); true }
                        end
                        assert (Time.now - base_time) >= 1
                    end
                    it "uses the given description for to_s" do
                        expectation = nil
                        expect_execution.timeout(0).to do
                            expectation = maintain(description: "some text") { true }
                        end
                        assert_equal "some text", expectation.to_s
                    end
                    it "accepts a proc as description, to be resolved when needed" do
                        expectation = nil
                        value = 0
                        expect_execution.timeout(0).to do
                            expectation =
                                maintain(description: -> { value.to_s }) { value = 10 }
                        end

                        assert_equal "10", expectation.to_s
                    end
                    it "ignores non-LocalizedError exceptions" do
                        assert_predicate_ignores_framework_error(
                            predicates: proc { maintain(at_least_during: 0.2) { true } }
                        )
                    end
                end

                describe "#achieve" do
                    it "succeeds if the block returns true" do
                        expect_execution.to { achieve { true } }
                    end
                    it "fails if the block never returns true" do
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution.timeout(0).to { achieve {} }
                        end
                    end
                    it "remains achieved once it did" do
                        # This tests the behaviour of Achieve given that
                        # ExecutionExpectations evaluates #update_match multiple
                        # times.
                        flipflop = false
                        expect_execution.timeout(0).to do
                            achieve { flipflop = !flipflop }
                        end
                    end
                    it "returns the block's value" do
                        obj = flexmock
                        ret = expect_execution.timeout(0).to do
                            achieve { obj }
                        end
                        assert_same obj, ret
                    end
                    it "uses the given description for to_s" do
                        expectation = nil
                        expect_execution.timeout(0).to do
                            expectation = achieve(description: "some text") { true }
                        end
                        assert_equal "some text", expectation.to_s
                    end
                    it "accepts a proc as description, to be resolved when needed" do
                        expectation = nil
                        value = 0
                        expect_execution.timeout(0).to do
                            expectation =
                                achieve(description: -> { value.to_s }) { value = 10 }
                        end

                        assert_equal "10", expectation.to_s
                    end
                    it "ignores non-LocalizedError exceptions" do
                        assert_predicate_ignores_framework_error(
                            predicates: proc { achieve { true } }
                        )
                    end
                end

                describe "#not_finalize" do
                    it "succeeds if the object remains in the plan" do
                        plan.add(plan_object = Roby::Task.new)
                        expect_execution.to { not_finalize plan_object }
                    end
                    it "fails if the plan object is removed from the plan" do
                        plan.add(plan_object = Roby::Task.new)
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { plan.remove_task(plan_object) }
                                .timeout(0).to { not_finalize plan_object }
                        end
                    end
                    it "ignores non-LocalizedError exceptions" do
                        plan.add(plan_object = Roby::Task.new)
                        assert_predicate_ignores_framework_error(
                            predicates: proc { not_finalize plan_object }
                        )
                    end
                end
                describe "#finalize" do
                    it "succeeds if the object is removed from the plan" do
                        plan.add(plan_object = Roby::Task.new)
                        expect_execution { plan.remove_task(plan_object) }
                            .to { finalize plan_object }
                    end
                    it "does not succeeds if the plan object remains in the plan" do
                        plan.add(plan_object = Roby::Task.new)
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution.timeout(0).to { finalize plan_object }
                        end
                    end
                    it "ignores non-LocalizedError exceptions" do
                        plan.add(plan_object = Roby::Task.new)
                        assert_predicate_ignores_framework_error(
                            execute: proc { plan.remove_task(plan_object) },
                            predicates: proc { finalize plan_object }
                        )
                    end
                end

                describe "not_become_unreachable" do
                    it "succeeds if the generator does not becomes unreachable" do
                        plan.add(generator = Roby::EventGenerator.new)
                        expect_execution
                            .to { not_become_unreachable generator }
                    end
                    it "fails if the generator does become unreachable" do
                        plan.add(generator = Roby::EventGenerator.new)
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { generator.unreachable! }
                                .to { not_become_unreachable generator }
                        end
                    end
                    it "ignores non-LocalizedError exceptions" do
                        plan.add(generator = Roby::EventGenerator.new)
                        assert_predicate_ignores_framework_error(
                            predicates: proc { not_become_unreachable generator }
                        )
                    end
                end
                describe "become_unreachable" do
                    it "succeeds if the generator becomes unreachable" do
                        plan.add(generator = Roby::EventGenerator.new)
                        expect_execution { generator.unreachable! }
                            .to { become_unreachable generator }
                    end
                    it "returns the unreachability reason" do
                        error_m = Class.new(RuntimeError)
                        plan.add(generator = Roby::EventGenerator.new)
                        reason = expect_execution { generator.unreachable!(error_m.new) }
                            .to { become_unreachable generator }
                        assert_kind_of error_m, reason
                    end
                    it "fails if the generator does not become unreachable" do
                        plan.add(generator = Roby::EventGenerator.new)
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution.timeout(0)
                                .to { become_unreachable generator }
                        end
                    end
                    it "ignores non-LocalizedError exceptions" do
                        plan.add(generator = Roby::EventGenerator.new)
                        assert_predicate_ignores_framework_error(
                            execute: proc { generator.unreachable! },
                            predicates: proc { become_unreachable generator }
                        )
                    end
                end

                describe "#quarantine" do
                    it "matches if the task is quarantined" do
                        plan.add(task = Roby::Task.new)
                        expect_execution { task.quarantined! }.to { quarantine(task) }
                    end
                    it "fails if the task is not quarantined" do
                        plan.add(task = Roby::Task.new)
                        assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution.timeout(0.1).to { quarantine(task) }
                        end
                    end
                    it "ignores the QuarantinedTaskError" do
                        plan.add_mission_task(task = Roby::Task.new)
                        expect_execution { task.quarantined! }.to { quarantine(task) }
                    end
                    it "ignores non-LocalizedError exceptions" do
                        plan.add(task = Roby::Task.new)
                        assert_predicate_ignores_framework_error(
                            execute: proc { task.quarantined! },
                            predicates: proc { quarantine(task) }
                        )
                    end
                end

                describe "#ignore_errors_from" do
                    it "passes if the predicate matches" do
                        plan.add(parent_task = Tasks::Simple.new)
                        task = parent_task.depends_on(Tasks::Simple.new, failure: :start)

                        execute { parent_task.start! }
                        expect_execution { task.start! }
                            .to { ignore_errors_from emit(task.start_event) }
                    end

                    it "does not require the predicate to match" do
                        plan.add(task = Roby::Task.new)
                        expect_execution.to { ignore_errors_from emit(task.start_event) }
                    end

                    it "ignores errors related to the predicate" do
                        plan.add_mission_task(task = Roby::Task.new)
                        expect_execution { task.quarantined! }.to do
                            ignore_errors_from quarantine(task)
                        end
                    end

                    it "calls update_match on the underlying predicates "\
                       "and ignores the result" do
                        plan.add_mission_task(task = Roby::Task.new)
                        expect_execution { task.quarantined! }.to do
                            matcher = quarantine(task)
                            flexmock(matcher).should_receive(:update_match).at_least.once
                                             .and_return(true)
                            ignore_errors_from matcher
                        end
                    end
                end
            end

            describe "#execute" do
                attr_reader :achieve_without_memory

                before do
                    @achieve_without_memory = Class.new(ExecutionExpectations::Achieve) do
                        def update_match(all_propagation_info)
                            @block.call(all_propagation_info)
                        end
                    end
                end

                it "allows to queue work from within the expectation block" do
                    values = []
                    achieved = false
                    expect_execution.to do
                        achieve do
                            execute { achieved = true }
                            values << achieved
                            achieved
                        end
                    end
                    assert_equal [false, true], values[0, 2]
                end
                it "forces the expectation loop to run one more event processing loop" do
                    values = []
                    achieved = false
                    expect_execution.timeout(60).to do
                        block = proc do
                            execute { achieved = true } unless achieved
                            values << achieved
                            true
                        end
                        add_expectation achieve_without_memory.new(block, "", [])
                    end
                    assert_equal [false, true], values[0, 2]
                end
            end

            describe "#start" do
                attr_reader :task

                before do
                    plan.add(@task = Roby::Tasks::Simple.new)
                end

                it "succeeds if the task starts" do
                    expect_execution { task.start! }.to { start task }
                end
                it "succeeds if the task starts and stops" do
                    expect_execution { task.start!; task.stop! }.to { start task }
                end
                it "fails if the task is already finished" do
                    execute { task.start!; task.stop! }
                    assert_raises(ExecutionExpectations::Unmet) do
                        expect_execution.to { start task }
                    end
                end
                it "fails if the task has failed-to-start" do
                    execute { task.failed_to_start!(ArgumentError.new) }
                    assert_raises(ExecutionExpectations::Unmet) do
                        expect_execution.to { start task }
                    end
                end
                it "fails if the task is already running" do
                    execute { task.start! }
                    assert_raises(ExecutionExpectations::Unmet) do
                        expect_execution.timeout(0).to { start task }
                    end
                end
                it "fails if the task does not emit the start event" do
                    assert_raises(ExecutionExpectations::Unmet) do
                        expect_execution.timeout(0).to { start task }
                    end
                end
                it "ignores non-LocalizedError exceptions" do
                    plan.add(task = Roby::Tasks::Simple.new)
                    assert_predicate_ignores_framework_error(
                        execute: proc { task.start! },
                        predicates: proc { start task }
                    )
                end
            end

            describe "#have_running" do
                attr_reader :task

                before do
                    plan.add(@task = Roby::Tasks::Simple.new)
                end

                it "fails if the task is already finished" do
                    execute { task.start!; task.stop! }
                    assert_raises(ExecutionExpectations::Unmet) do
                        expect_execution.to { have_running task }
                    end
                end
                it "fails if the task has failed-to-start" do
                    execute { task.failed_to_start!(ArgumentError.new) }
                    assert_raises(ExecutionExpectations::Unmet) do
                        expect_execution.to { start task }
                    end
                end
                it "succeeds if the task is already running and does not stop" do
                    execute { task.start! }
                    expect_execution.timeout(0).to { have_running task }
                end
                it "succeeds if the task was pending, starts and does not stop" do
                    expect_execution { task.start! }
                        .timeout(0)
                        .to { have_running task }
                end
                it "fails if the task was pending, starts but also stops" do
                    assert_raises(ExecutionExpectations::Unmet) do
                        expect_execution { task.start!; task.stop! }
                            .timeout(0)
                            .to { have_running task }
                    end
                end
                it "fails if the task was running and stops" do
                    assert_raises(ExecutionExpectations::Unmet) do
                        execute { task.start! }
                        expect_execution { task.stop! }
                            .timeout(0)
                            .to { have_running task }
                    end
                end
                it "ignores non-LocalizedError exceptions" do
                    plan.add(task = Roby::Tasks::Simple.new)
                    assert_predicate_ignores_framework_error(
                        execute: proc { task.start! },
                        predicates: proc { have_running task }
                    )
                end
            end

            def assert_predicate_ignores_framework_error(
                execute: proc {}, predicates: proc {}
            )
                e = Exception.new
                unexpected_e =
                    assert_raises(ExecutionExpectations::UnexpectedErrors) do
                        expect_execution do
                            execution_engine.add_framework_error(e, "")
                            instance_eval(&execute)
                        end.to do
                            instance_eval(&predicates)
                        end
                    end
                assert_equal [e], unexpected_e.each_original_exception.to_a
            end
        end
    end
end
