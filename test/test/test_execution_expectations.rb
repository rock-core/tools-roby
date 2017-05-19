require 'roby/test/self'

module Roby
    module Test
        describe ExecutionExpectations do
            describe "#expect_execution" do
                it "executes the first block in propagation context" do
                    plan.add(task = Roby::Tasks::Simple.new)
                    expect_execution { task.start! }.to { }
                    assert task.running?
                end

                it "executes the first block after the to ... block" do
                    plan.add(task = Roby::Tasks::Simple.new)
                    executed, to_executed, was_expect_executed = false
                    expect_execution do
                        executed = true
                    end.to do
                        to_executed = true
                        was_expect_executed = executed
                    end
                    assert to_executed
                    refute was_expect_executed
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
                        execution_engine.should_receive(:process_events).
                            pass_thru { |ret| refute execution_engine.scheduler.enabled?; ret }
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
                        execution_engine.should_receive(:process_events).
                            pass_thru { |ret| assert execution_engine.scheduler.enabled?; ret }
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
                        execution_engine.should_receive(:process_events).
                            with(hsh(garbage_collect_pass: true)).
                            pass_thru
                    end
                    it "calls process_events with garbage_collect_pass: false if #garbage_collect is false" do
                        expectations.garbage_collect false
                        execution_engine.should_receive(:process_events).
                            with(hsh(garbage_collect_pass: false)).
                            pass_thru
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
                            execution_engine.should_receive(:has_waiting_work?).
                                and_return(true, false)
                            execution_engine.should_receive(:process_events).twice.
                                and_return(ExecutionEngine::PropagationInfo.new)
                            expectations.verify
                        end

                        it "executes the block only once" do
                            execution_engine.should_receive(:has_waiting_work?).
                                and_return(true, false)
                            recorder = flexmock
                            recorder.should_receive(:called).with(true).once
                            expectations.verify { recorder.called(execution_engine.in_propagation_context?) }
                        end

                        it "raises if there are unachievable expectations" do
                            execution_engine.should_receive(:has_waiting_work?).
                                and_return(true)
                            expectations.add_expectation(
                                flexmock(explain_unachievable: "", update_match: false, unachievable?: true))
                            assert_raises(ExecutionExpectations::Unmet) do
                                expectations.timeout 0
                                expectations.verify {}
                            end
                        end
                    end

                    describe "with join_all_waiting_work unset" do
                        before do
                            expectations.join_all_waiting_work false
                            execution_engine.should_receive(:has_waiting_work?).
                                and_return(true)
                        end

                        it "executes the loop only once" do
                            execution_engine.should_receive(:process_events).once.
                                pass_thru
                            expectations.verify
                        end

                        it "executes the block once in propagation context" do
                            recorder = flexmock
                            recorder.should_receive(:called).with(true).once
                            expectations.verify { recorder.called(execution_engine.in_propagation_context?) }
                        end

                        it "raises if there are unachievable expectations" do
                            expectations.add_expectation(
                                flexmock(explain_unachievable: "", update_match: false, unachievable?: true))
                            assert_raises(ExecutionExpectations::Unmet) do
                                expectations.timeout 0
                                expectations.verify {}
                            end
                        end

                        it "raises if there are unmet expectations" do
                            expectations.add_expectation(
                                flexmock(update_match: false, unachievable?: false))
                            assert_raises(ExecutionExpectations::Unmet) do
                                expectations.timeout 0
                                expectations.verify {}
                            end
                        end
                    end
                end
            end

            describe "standard expectations" do
                describe "#emits" do
                    it "validates when the event is emitted" do
                        plan.add(generator = EventGenerator.new)
                        expect_execution { generator.emit }.
                            to { emit generator }
                    end
                    it "fails if the event is not emitted" do
                        plan.add(generator = EventGenerator.new)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution {}.with_setup { timeout 0 }.
                                to { emit generator }
                        end
                        assert_equal "1 unmet expectations\nemission of #{generator}", e.message
                    end
                    it "fails if the event becomes unreachable" do
                        plan.add(generator = EventGenerator.new)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { generator.unreachable! }.
                                with_setup { timeout 0 }.to { emit generator }
                        end
                        assert_equal "1 unmet expectations\nemission of #{generator}", e.message
                    end
                    it "reports unreachability reason if there is one" do
                        plan.add(generator = EventGenerator.new)
                        plan.add(cause = EventGenerator.new)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution { generator.unreachable!(cause) }.
                                with_setup { timeout 0 }.to { emit generator }
                        end
                        assert_equal "1 unmet expectations\nemission of #{generator} because of #{PP.pp(cause, "", 0).chomp}", e.message
                    end
                    it "validates if the event's emission caused exceptions" do
                        plan.add(generator = EventGenerator.new)
                        expect_execution do
                            generator.emit
                            generator.on { |ev| execution_engine.add_error(
                                LocalizedError.new(ev)) }
                        end.to { emit generator }
                    end
                end

                describe "#have_error_matching" do
                    it "validates when the exception has been raised" do
                        plan.add(task = Roby::Task.new)
                        matcher = flexmock
                        matcher.should_receive(:exception_matcher).and_return(flexmock)
                        matcher.should_receive(:===).
                            with(->(e) { e.exception.failed_generator == task.start_event }).
                            and_return(true)
                        expect_execution do
                            execution_engine.add_error(LocalizedError.new(task.start_event))
                        end.to { have_error_matching flexmock(to_execution_exception_matcher: matcher) }
                    end
                    it "fails if only non-matching exceptions have been raised" do
                        plan.add(task = Roby::Task.new)
                        matcher = flexmock
                        matcher.should_receive(:exception_matcher).and_return(flexmock)
                        matcher.should_receive(:===).
                            with(->(e) { e.exception.failed_generator == task.start_event }).
                            and_return(false)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution do
                                execution_engine.add_error(LocalizedError.new(task.start_event))
                            end.with_setup { timeout 0 }.to do
                                have_error_matching LocalizedError
                                have_error_matching flexmock(to_execution_exception_matcher: matcher)
                            end
                        end
                        assert_match /^1 unmet expectations\nhas error matching #{matcher}/m, e.message
                    end
                    it "fails if no exceptions have been raised" do
                        plan.add(task = Roby::Task.new)
                        matcher = flexmock
                        matcher.should_receive(:exception_matcher).and_return(flexmock)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution {}.
                                with_setup { timeout 0 }.to { have_error_matching flexmock(to_execution_exception_matcher: matcher) }
                        end
                        assert_match /^1 unmet expectations\nhas error matching #{matcher}/m, e.message
                    end
                    it "validates even if the exception causes other errors" do
                        plan.add(task = Roby::Task.new)
                        plan.add(other_task = Roby::Task.new)
                        matcher = flexmock
                        matcher.should_receive(:exception_matcher).and_return(flexmock)
                        matcher.should_receive(:===).
                            with(->(e) { e.exception.failed_generator == task.start_event }).
                            and_return(true)
                        expect_execution do
                            execution_engine.add_error(error = LocalizedError.new(task.start_event))
                            other_error = LocalizedError.new(other_task.start_event)
                            other_error.report_exceptions_from(error)
                        end.to { have_error_matching flexmock(to_execution_exception_matcher: matcher) }
                    end
                end

                describe "#have_handled_error_matching" do
                    attr_reader :matcher
                    before do
                        @error_m = Class.new(LocalizedError)
                        @task_m = Roby::Task.new_submodel
                        @task_m.on_exception(@error_m) { |e| }
                        plan.add(@task = @task_m.new)
                        @matcher = flexmock
                        @matcher.should_receive(:exception_matcher).and_return(flexmock)
                    end

                    it "validates when the exception has been raised and handled" do
                        @matcher.should_receive(:===).
                            with(->(e) { e.exception.failed_generator == @task.start_event }).
                            and_return(true)
                        expect_execution do
                            execution_engine.add_error(@error_m.new(@task.start_event))
                        end.to { have_handled_error_matching flexmock(to_execution_exception_matcher: matcher) }
                    end
                    it "fails if only non-matching exceptions have been raised" do
                        @matcher.should_receive(:===).
                            with(->(e) { e.exception.failed_generator == @task.start_event }).
                            and_return(false)
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution do
                                execution_engine.add_error(@error_m.new(@task.start_event))
                            end.with_setup { timeout 0 }.
                            to { have_handled_error_matching flexmock(to_execution_exception_matcher: matcher) }
                        end
                        assert_match /^1 unmet expectations\nhas handled error matching #{matcher}/m, e.message
                    end
                    it "fails if no exceptions have been raised" do
                        e = assert_raises(ExecutionExpectations::Unmet) do
                            expect_execution {}.
                                with_setup { timeout 0 }.
                                to { have_handled_error_matching flexmock(to_execution_exception_matcher: matcher) }
                        end
                        assert_match /^1 unmet expectations\nhas handled error matching #{matcher}/m, e.message
                    end
                    it "validates even if the exception causes other errors" do
                        plan.add(other_task = Roby::Task.new)
                        @matcher.should_receive(:===).
                            with(->(e) { e.exception.failed_generator == @task.start_event }).
                            and_return(true)
                        expect_execution do
                            execution_engine.add_error(error = @error_m.new(@task.start_event))
                            other_error = @error_m.new(other_task.start_event)
                            other_error.report_exceptions_from(error)
                        end.to { have_handled_error_matching flexmock(to_execution_exception_matcher: matcher) }
                    end
                end
            end
        end
    end
end

