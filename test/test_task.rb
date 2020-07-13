# frozen_string_literal: true

require "roby/test/self"
require "roby/tasks/group"
require "roby/schedulers/basic"

module Roby
    class TaskTest
        include Minitest::Spec::DSL

        describe "state flags" do
            def state_predicates
                %i[pending? failed_to_start? starting? started? running? success? failed? finishing? finished?]
            end

            def assert_task_in_states(task, *states)
                neg_states = state_predicates - states
                states.each do |s|
                    assert task.send(s), "expected #{task} to be #{s}"
                    if Queries::Index::STATE_PREDICATES.include?(s)
                        assert plan.find_tasks.send(s.to_s[0..-2]).to_a.include?(task)
                    end
                end
                neg_states.each do |s|
                    refute task.send(s), "expected #{task} to not be #{s}"
                    if Queries::Index::STATE_PREDICATES.include?(s)
                        assert plan.find_tasks.send("not_#{s}"[0..-2]).to_a.include?(task)
                    end
                end
            end

            it "is pending on a new task" do
                plan.add(task = Tasks::Simple.new)
                assert_task_in_states task, :pending?
            end

            it "is starting on a new task whose start event's call command is pending" do
                plan.add(task = Tasks::Simple.new)
                execute do
                    task.start!
                    assert_task_in_states task, :starting?
                end
            end

            it "is failed_to_start? on a new task whose start event's call command has been pending but failed" do
                task_m = Task.new_submodel do
                    terminates
                    event :start do |context|
                    end
                end
                plan.add(task = task_m.new)
                execute { task.start! }
                execute do
                    task.start_event.emit_failed RuntimeError.new
                end
                assert_task_in_states task, :failed_to_start?, :failed?
            end

            it "is starting on a new task whose start event's call command has been called" do
                task_m = Task.new_submodel do
                    terminates
                    event :start do |context|
                    end
                end
                plan.add(task = task_m.new)
                execute { task.start! }
                assert_task_in_states task, :starting?
                execute { task.start_event.emit }
            end

            it "is back to pending if a call fails during propagation" do
                task_m = Task.new_submodel do
                    terminates
                    event :start do |context|
                    end
                end
                plan.add(task = task_m.new)
                flexmock(task.start_event)
                    .should_receive(:check_call_validity_after_calling)
                    .and_return(TaskEventNotExecutable.new(task.start_event))
                expect_execution { task.start! }
                    .to { have_error_matching TaskEventNotExecutable }
                assert_task_in_states task, :pending?
            end

            it "is started and running on a task whose start event has been emitted" do
                plan.add(task = Tasks::Simple.new)
                execute { task.start! }
                assert_task_in_states task, :started?, :running?
            end

            it "is started and finished on a task whose stop event has been emitted" do
                plan.add(task = Tasks::Simple.new)
                execute do
                    task.start!
                    task.stop_event.emit
                end
                assert_task_in_states task, :started?, :finished?
            end

            it "is started, finished and failed on a task whose failed event has been emitted" do
                plan.add(task = Tasks::Simple.new)
                execute do
                    task.start!
                    task.failed_event.emit
                end
                assert_task_in_states task, :started?, :finished?, :failed?
            end

            it "is started, finished and successful on a task whose success event has been emitted" do
                plan.add(task = Tasks::Simple.new)
                execute do
                    task.start!
                    task.success_event.emit
                end
                assert_task_in_states task, :started?, :finished?, :success?
            end
        end

        describe "the failure of the start command" do
            it "sets failed_to_start if the start command fails before the start event was emitted" do
                error = Class.new(ArgumentError).new
                task_m = Roby::Tasks::Simple.new_submodel do
                    event :start do |context|
                        raise error
                    end
                end
                plan.add(task = task_m.new)
                execute { task.start! }
                assert task.failed_to_start?, "#{task} is not marked as failed to start but should be"
                assert_kind_of Roby::CommandFailed, task.failure_reason
                assert_equal error, task.failure_reason.error
                assert task.failed?
            end

            it "marks failed_to_start so that schedulers don't reconsider the task" do
                scheduler = Schedulers::Basic.new(false, plan)
                error = Class.new(ArgumentError).new
                task_m = Roby::Tasks::Simple.new_submodel do
                    event :start do |context|
                        raise error
                    end
                end
                plan.add(task = task_m.new)
                expect_execution.scheduler(scheduler)
                    .to do
                        fail_to_start task
                    end
            end

            it "emits the internal error if it fails after it emitted the event" do
                error = Class.new(ArgumentError)
                task_m = Roby::Tasks::Simple.new_submodel do
                    event :start do |context|
                        start_event.emit
                        raise error
                    end
                end
                plan.add(task = task_m.new)
                expect_execution { task.start! }
                    .to do
                        have_handled_error_matching error
                        emit task.internal_error_event
                    end

                refute task.failed_to_start?, "#{task} is marked as failed to start but should not be"
                refute task.running?
                assert task.internal_error?
            end
        end

        describe "inspect method" do
            it "is pending on a new task" do
                plan.add(task = Tasks::Simple.new)
                assert task.inspect.include? "pending"
            end

            it "has failed to start" do
                task_m = Task.new_submodel do
                    terminates
                    event :start do |context|
                    end
                end
                plan.add(task = task_m.new)
                execute { task.start! }
                execute do
                    task.start_event.emit_failed RuntimeError.new
                end
                assert task.inspect.include? "failed"
            end

            it "is starting" do
                task_m = Task.new_submodel do
                    terminates
                    event :start do |context|
                    end
                end
                plan.add(task = task_m.new)
                execute { task.start! }
                assert task.inspect.include? "starting"
                execute { task.start_event.emit }
            end

            it "is running" do
                plan.add(task = Tasks::Simple.new)
                execute { task.start! }
                assert task.inspect.include? "running"
            end

            it "is finishing" do
                task_m = Task.new_submodel do
                    event :stop do |_|
                    end
                end
                plan.add(task = task_m.new)
                execute do
                    task.start!
                    task.stop!
                end
                assert task.inspect.include? "finishing"
                execute { task.stop_event.emit }
            end

            it "has finished" do
                plan.add(task = Tasks::Simple.new)
                execute do
                    task.start!
                    task.stop_event.emit
                end
                assert task.inspect.include? "finished"
            end
        end

        describe "handling of CodeError originating from the task" do
            describe "a pending task" do
                it "passes the exception" do
                    plan.add(task = Tasks::Simple.new)
                    expect_execution do
                        execution_engine.add_error(CodeError.new(ArgumentError.new, task))
                    end.to do
                        have_error_matching CodeError.match
                            .with_ruby_exception(ArgumentError)
                            .with_origin(task)
                    end
                end
            end
            describe "failed-to-start task" do
                it "passes the exception" do
                    plan.add(task = Tasks::Simple.new)
                    expect_execution do
                        task.failed_to_start!(ArgumentError.new)
                        execution_engine.add_error(CodeError.new(ArgumentError.new, task))
                    end.to do
                        have_error_matching CodeError.match
                            .with_ruby_exception(ArgumentError)
                            .with_origin(task)
                    end
                end
            end
            describe "a finished task" do
                it "passes the exception" do
                    plan.add(task = Tasks::Simple.new)
                    expect_execution do
                        task.start!
                        task.stop!
                        execution_engine.add_error(CodeError.new(ArgumentError.new, task))
                    end.to do
                        have_error_matching CodeError.match
                            .with_ruby_exception(ArgumentError)
                            .with_origin(task)
                    end
                end
            end
            describe "a starting task" do
                after do
                    @task.start_event.emit if @task.starting?
                end
                it "marks the task as failed-to-start if the error's origin "\
                   "is the task's start_event" do
                    task_m = Tasks::Simple.new_submodel do
                        event :start do |context|
                        end
                    end
                    plan.add(@task = task = task_m.new)
                    expect_execution do
                        task.start!
                        execution_engine.add_error(
                            CodeError.new(ArgumentError.new, task.start_event)
                        )
                    end.to do
                        fail_to_start task, reason: CodeError.match
                            .with_ruby_exception(ArgumentError)
                            .with_origin(task.start_event)
                    end
                end
            end
            describe "a running task" do
                after do
                    execute { @task.stop_event.emit } if @task&.stop_event&.pending?
                end

                it "handles the error and emits internal_error_event "\
                   "with the error as context" do
                    plan.add(task = Tasks::Simple.new)
                    error_matcher =
                        CodeError
                        .match.with_ruby_exception(ArgumentError).with_origin(task)

                    event = expect_execution do
                        task.start!
                        execution_engine.add_error(CodeError.new(ArgumentError.new, task))
                    end.to do
                        have_handled_error_matching error_matcher
                        emit task.internal_error_event
                    end
                    assert error_matcher === event.context.first
                end

                it "does not emit internal_error_event twice" do
                    task_m = Task.new_submodel
                    task_m.event(:stop) { |context| }
                    plan.add(@task = task = task_m.new)
                    error_matcher =
                        CodeError
                        .match.with_ruby_exception(ArgumentError).with_origin(task)

                    expect_execution do
                        task.start!
                        execution_engine.add_error(
                            CodeError.new(ArgumentError.exception("first error"), task)
                        )
                    end.to do
                        have_handled_error_matching error_matcher
                        emit task.internal_error_event
                    end
                    assert task.stop_event.pending?

                    expect_execution do
                        execution_engine.add_error(
                            CodeError.new(ArgumentError.exception("second error"), task)
                        )
                    end.to do
                        have_handled_error_matching error_matcher
                        have_error_matching(
                            TaskEmergencyTermination
                            .match.with_origin(task)
                            .with_original_exception(error_matcher)
                        )
                    end
                    assert task.quarantined?
                end
            end
        end

        describe "event validation" do
            attr_reader :task
            before do
                model = Tasks::Simple.new_submodel do
                    event(:inter, command: true)
                end
                plan.add(@task = model.new)
                plan.execution_engine.display_exceptions = false
            end

            after do
                plan.execution_engine.display_exceptions = true
            end

            describe "a pending task" do
                it "raises if calling an intermediate event" do
                    execute do
                        assert_raises(CommandRejected.match.with_origin(task.inter_event)) do
                            task.inter!
                        end
                    end
                    assert !task.inter_event.pending?
                end
                it "raises if emitting an intermediate event" do
                    execute do
                        assert_raises(EmissionRejected.match.with_origin(task.inter_event)) do
                            task.inter_event.emit
                        end
                    end
                end
            end

            describe "a running task" do
                before do
                    execute { task.start! }
                end
                it "raises if calling the start event" do
                    execute do
                        assert_raises(CommandRejected) { task.start! }
                    end
                end
            end
            describe "a finished task" do
                before do
                    execute do
                        task.start!
                        task.inter!
                        task.stop!
                    end
                end
                it "raises if calling an intermediate event" do
                    execute do
                        assert_raises(CommandRejected) { task.inter! }
                    end
                end
                it "raises if emitting an intermediate event" do
                    execute do
                        assert_raises(TaskEventNotExecutable) { task.inter_event.emit }
                    end
                end
            end

            it "correctly handles unordered emissions during the propagation phase" do
                model = Tasks::Simple.new_submodel do
                    event :start do |context|
                        inter_event.emit
                        start_event.emit
                    end

                    event :inter do |context|
                        inter_event.emit
                    end
                end
                plan.add(task = model.new)
                execute { task.start! }
                assert task.inter_event.emitted?
            end
        end

        describe "model-level event handlers" do
            attr_reader :task_m
            before do
                @task_m = Tasks::Simple.new_submodel
            end

            it "calls the handler at runtime" do
                mock = flexmock
                task_m.on(:start) { |_| mock.start_called }
                plan.add(task = task_m.new)
                mock.should_receive(:start_called).once
                execute { task.start! }
            end

            it "evaluates the block in the instance's context" do
                mock = flexmock
                task_m.on(:start) { |_| mock.start_called(self) }
                plan.add(task = task_m.new)
                mock.should_receive(:start_called).with(task)
                execute { task.start! }
            end

            it "does not add the handlers on its parent model" do
                mock = flexmock
                task_m.on(:start) { |_| mock.start_called }
                plan.add(task = Tasks::Simple.new)
                mock.should_receive(:start_called).never
                execute { task.start! }
            end
        end

        describe "the argument handling" do
            describe "assign_arguments" do
                let(:task_m) do
                    Task.new_submodel do
                        argument :high_level_arg
                        argument :low_level_arg
                        def high_level_arg=(value)
                            arguments[:low_level_arg] = 10
                            arguments[:high_level_arg] = 10
                        end
                    end
                end

                it "allows for the same argument to be set twice to the same value" do
                    task = task_m.new
                    task.assign_arguments(low_level_arg: 10, high_level_arg: 10)
                    assert_equal 10, task.low_level_arg
                    assert_equal 10, task.high_level_arg
                end
                it "raises if the same argument is set twice to different values" do
                    task = task_m.new
                    assert_raises(ArgumentError) do
                        task.assign_arguments(low_level_arg: 20, high_level_arg: 10)
                    end
                end
                it "properly overrides a delayed argument" do
                    # There was a bug in which a delayed argument would not be
                    # overriden because it would be set when the first argument
                    # was handled and then reset when the second was
                    delayed_arg = flexmock
                    delayed_arg.should_receive(:evaluate_delayed_argument).with(task_m).and_return(10)
                    task = task_m.new(high_level_arg: delayed_arg)
                    task.assign_arguments(high_level_arg: 10, low_level_arg: 10)
                    assert_equal 10, task.high_level_arg
                    assert_equal 10, task.low_level_arg
                end

                it "does parallel-assignment of arguments given to it at initialization" do
                    task_m = Class.new(self.task_m) do
                        attr_reader :parallel_assignment
                        def assign_arguments(**args)
                            @parallel_assignment = args
                            super
                        end
                    end
                    task = task_m.new(high_level_arg: 10, low_level_arg: 10)
                    assert_equal Hash[high_level_arg: 10, low_level_arg: 10], task.parallel_assignment
                end

                it "does parallel-assignment of delayed arguments in #freeze_delayed_arguments" do
                    delayed_arg = flexmock
                    delayed_arg.should_receive(:evaluate_delayed_argument).with(task_m).and_return(10)

                    plan.add(task = task_m.new(high_level_arg: delayed_arg))
                    flexmock(task).should_receive(:assign_arguments)
                        .once.with(high_level_arg: 10)
                    task.freeze_delayed_arguments
                end
            end
        end

        describe "#last_event" do
            attr_reader :task
            before do
                plan.add(@task = Roby::Tasks::Simple.new)
            end
            it "returns nil if no event has ever been emitted" do
                assert_nil task.last_event
            end
            it "returns the last emitted event if some where emitted" do
                execute { task.start_event.emit }
                assert_equal task.start_event.last, task.last_event
                execute { task.stop_event.emit }
                assert_equal task.stop_event.last, task.last_event
            end
        end

        describe "abstract-ness" do
            it "is not abstract if its model is not" do
                plan.add(task = Roby::Task.new_submodel.new)
                assert !task.abstract?
            end
            it "is abstract if its model is" do
                plan.add(task = Roby::Task.new_submodel { abstract }.new)
                assert task.abstract?
            end
            it "is overriden with #abstract=" do
                plan.add(task = Roby::Task.new_submodel { abstract }.new)
                task.abstract = false
                assert !task.abstract?
                task.abstract = true
                assert task.abstract?
            end
            it "is not executable if it is abstract" do
                plan.add(task = Roby::Task.new_submodel { abstract }.new)
                task.abstract = false
                assert task.executable?
                task.abstract = true
                assert !task.executable?
            end
        end

        describe "transaction proxies" do
            subject { plan.add(t = Roby::Task.new); t }

            it "does not wrap any events on a standalone task" do
                plan.in_transaction do |trsc|
                    trsc[subject].each_event.empty?
                end
            end

            it "wraps events that have relations outside the task itself" do
                root, task = prepare_plan add: 2
                root.start_event.signals task.start_event
                plan.in_transaction do |trsc|
                    assert_equal [:start], trsc[task].each_event.map(&:symbol)
                end
            end

            it "wraps events on demand" do
                plan.in_transaction do |trsc|
                    p = trsc[subject]
                    assert trsc.task_events.empty?
                    start = p.start_event
                    refute_same subject.start_event, start
                    assert_equal [start], p.each_event.to_a
                    assert_same start, p.start_event
                    assert trsc.has_task_event?(p.start_event)
                end
            end

            it "copies copy_on_replace handlers from the plan even if the source generator is not wrapped" do
                source, target = prepare_plan add: 2
                source.start_event.on(on_replace: :copy) {}
                plan.in_transaction do |trsc|
                    p_source, p_target = trsc[source], trsc[target]
                    trsc.replace_task(p_source, p_target)
                    assert_equal [:start], p_target.each_event.map(&:symbol)
                    trsc.commit_transaction
                end
                assert_equal source.start_event.handlers, target.start_event.handlers
            end

            it "copies copy_on_replace handlers from the plan if the source generator is wrapped" do
                source, target = prepare_plan add: 2
                source.start_event.on(on_replace: :copy) {}
                plan.in_transaction do |trsc|
                    p_source, p_target = trsc[source], trsc[target]
                    p_source.start_event
                    trsc.replace_task(p_source, p_target)
                    assert_equal [:start], p_target.each_event.map(&:symbol)
                    trsc.commit_transaction
                end
                assert_equal source.start_event.handlers, target.start_event.handlers
            end

            it "propagates the argument's static flag from plan to transaction" do
                plan.add(task = Tasks::Simple.new(id: DefaultArgument.new(10)))
                plan.in_transaction do |t|
                    assert !t[task].arguments.static?
                end
            end
        end

        describe "#instanciate_model_event_relations" do
            def self.common_instanciate_model_event_relations_behaviour
                it "adds a precedence link between the start event and all root intermediate events" do
                    # Add one root that forwards to something and one standalone
                    # event
                    plan.add(task = task_m.new)
                    assert(task.start_event.child_object?(
                               task.ev1_event, Roby::EventStructure::Precedence))
                    assert(!task.start_event.child_object?(
                        task.ev2_event, Roby::EventStructure::Precedence))
                    assert(task.start_event.child_object?(
                               task.ev3_event, Roby::EventStructure::Precedence))
                end

                it "adds a precedence link between the leaf intermediate events and the root terminal events" do
                    task.each_event do |ev|
                        if ev.terminal?
                            assert(!task.ev1_event.child_object?(
                                ev, Roby::EventStructure::Precedence))
                        end
                    end
                    %i[success aborted internal_error].each do |terminal|
                        assert(task.ev2_event.child_object?(
                                   task.event(terminal), Roby::EventStructure::Precedence), "ev2 is not marked as preceding #{terminal}")
                        assert(task.ev3_event.child_object?(
                                   task.event(terminal), Roby::EventStructure::Precedence), "ev3 is not marked as preceding #{terminal}")
                    end
                end
            end

            describe "start is not terminal" do
                let(:task_m) do
                    Roby::Tasks::Simple.new_submodel do
                        event :ev1
                        event :ev2
                        event :ev3
                        forward :ev1 => :ev2
                    end
                end
            end

            describe "start is terminal" do
                let(:task_m) do
                    Roby::Tasks::Simple.new_submodel do
                        event :ev1
                        event :ev2
                        event :ev3
                        forward :ev1 => :ev2
                        forward :start => :stop
                    end
                end
            end
        end

        describe "#execute" do
            let(:recorder) { flexmock }

            it "delays the block execution until the task starts" do
                plan.add(task = Roby::Tasks::Simple.new)
                task.execute do |t|
                    recorder.execute_called(t)
                end
                recorder.should_receive(:execute_called).with(task).once
                execute { task.start! }
            end

            it "yields in the next cycle on running tasks" do
                plan.add(task = Roby::Tasks::Simple.new)
                executed = false
                task.execute { |t| executed = true }
                expect_execution { task.start! }
                    .to { achieve { executed } }
            end

            describe "on_replace: :copy" do
                attr_reader :task, :replacement
                before do
                    plan.add(@task = Roby::Tasks::Simple.new(id: 1))
                    @replacement = Roby::Tasks::Simple.new(id: 1)
                    task.execute(on_replace: :copy) { |c| recorder.called(c) }
                    recorder.should_receive(:called).with(task).once
                    recorder.should_receive(:called).with(replacement).once
                end
                it "copies the handler on a replacement done in the plan" do
                    plan.add(replacement)
                    plan.replace_task(task, replacement)
                    execute { replacement.start! }
                    execute { task.start! }
                end
                it "copies the handlers on a replacement added and done in a transaction" do
                    PlanObject.debug_finalization_place = true
                    plan.in_transaction do |trsc|
                        trsc.add(replacement)
                        trsc.replace_task(trsc[task], replacement)
                        trsc.commit_transaction
                    end
                    execute { replacement.start! }
                    execute { task.start! }
                end
                it "copies the handlers on a replacement added in the plan and done in a transaction" do
                    plan.add(replacement)
                    plan.in_transaction do |trsc|
                        trsc.replace_task(trsc[task], trsc[replacement])
                        trsc.commit_transaction
                    end
                    execute { replacement.start! }
                    execute { task.start! }
                end
            end
        end

        describe "replace behaviors" do
            def self.it_matches_common_replace_transaction_behaviour_for_handler(handler_type, &create_handler)
                it "does not wrap the target event if the source event does not have a copy_on_replace #{handler_type}" do
                    task0, task1 = prepare_plan add: 2
                    create_handler.call(task0.start_event, on_replace: :drop) {}
                    plan.in_transaction do |trsc|
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        replace_op(p_task0, p_task1)
                        assert_equal [], p_task0.each_event.map(&:symbol)
                        assert_equal [], p_task1.each_event.map(&:symbol)
                        trsc.commit_transaction
                    end
                    assert_equal [], task1.start_event.send(handler_type).to_a
                end

                it "wraps the target event if the source event has a copy_on_replace #{handler_type} at the plan level" do
                    task0, task1 = prepare_plan add: 2
                    create_handler.call(task0.start_event, on_replace: :copy) {}
                    plan.in_transaction do |trsc|
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        replace_op(p_task0, p_task1)
                        assert_equal [], p_task0.each_event.map(&:symbol)
                        assert_equal [:start], p_task1.each_event.map(&:symbol)
                        trsc.commit_transaction
                    end
                    assert_equal 1, task0.start_event.send(handler_type).size
                    assert_equal task0.start_event.send(handler_type), task1.start_event.send(handler_type)
                end

                it "wraps the target event if the source event has a copy_on_replace #{handler_type} at the transaction level" do
                    task0, task1 = prepare_plan add: 2

                    plan.in_transaction do |trsc|
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        create_handler.call(p_task0.start_event, on_replace: :copy) {}
                        replace_op(p_task0, p_task1)
                        assert_equal [:start], p_task0.each_event.map(&:symbol)
                        assert_equal [:start], p_task1.each_event.map(&:symbol)
                        trsc.commit_transaction
                    end
                    assert_equal 1, task0.start_event.send(handler_type).size
                    assert_equal task0.start_event.send(handler_type), task1.start_event.send(handler_type)
                end
            end

            def self.it_matches_common_replace_transaction_behaviour
                it_matches_common_replace_transaction_behaviour_for_handler(:finalization_handlers) do |event, args|
                    event.when_finalized(**args) {}
                end
                it_matches_common_replace_transaction_behaviour_for_handler(:handlers) do |event, args|
                    event.on(**args) {}
                end
                it_matches_common_replace_transaction_behaviour_for_handler(:unreachable_handlers) do |event, args|
                    event.if_unreachable(**args) {}
                end
            end

            describe "#replace_subplan_by" do
                def replace(task0, task1)
                    task0.replace_subplan_by(task1)
                end

                describe "in a transaction" do
                    def replace_op(task0, task1)
                        task0.replace_subplan_by(task1)
                    end

                    def replace(task0, task1)
                        plan.in_transaction do |trsc|
                            p_task0, p_task1 = trsc[task0], trsc[task1]
                            p_task0.replace_subplan_by p_task1
                            trsc.commit_transaction
                        end
                    end

                    it_matches_common_replace_transaction_behaviour
                end
            end

            describe "#replace_by" do
                describe "in a transaction" do
                    def replace_op(task0, task1)
                        task0.replace_by(task1)
                    end

                    def replace(task0, task1)
                        plan.in_transaction do |trsc|
                            p_task0, p_task1 = trsc[task0], trsc[task1]
                            p_task0.replace_by p_task1
                            trsc.commit_transaction
                        end
                    end

                    it_matches_common_replace_transaction_behaviour
                end
            end
        end

        describe "#start_time" do
            subject { plan.add(t = Roby::Tasks::Simple.new); t }
            it "is nil on a pending task" do
                assert_nil subject.start_time
            end
            it "is the time of the start event" do
                execute { subject.start! }
                assert_equal subject.start_event.last.time, subject.start_time
            end
        end

        describe "#end_time" do
            subject { plan.add(t = Roby::Tasks::Simple.new); t }
            it "is nil on a unfinished task" do
                execute { subject.start! }
                assert_nil subject.end_time
            end
            it "is the time of the stop event" do
                execute { subject.start! }
                execute { subject.stop! }
                assert_equal subject.stop_event.last.time, subject.end_time
            end
        end

        describe "#lifetime" do
            subject { plan.add(t = Roby::Tasks::Simple.new); t }
            it "is nil on a pending task" do
                assert_nil subject.lifetime
            end

            it "is the time between the start event and now on a running task" do
                execute { subject.start! }
                t = Time.now
                flexmock(Time).should_receive(:now).and_return(t)
                assert_equal t - subject.start_event.last.time, subject.lifetime
            end

            it "is the time between the stop and start events on a finished task" do
                execute { subject.start! }
                execute { subject.stop! }
                assert_equal subject.end_time - subject.start_time, subject.lifetime
            end
        end

        describe "polling" do
            attr_reader :task_m
            before do
                @task_m = Tasks::Simple.new_submodel
            end

            it "is called once in the same cycle as the start event" do
                poll_cycles = []
                task_m.poll { poll_cycles << plan.execution_engine.propagation_id }

                plan.add_permanent_task(task = task_m.new)
                task.poll { |task| poll_cycles << task.plan.execution_engine.propagation_id }
                execute { task.start! }
                expected = task.start_event.history.first.propagation_id
                assert_equal [expected, expected], poll_cycles
            end

            it "has an empty default implementation that can be called with super()" do
                called = false
                task_m.poll { super(); called = true }
                plan.add(task = task_m.new)
                execute { task.start! }
                assert called
            end

            it "returns a disposable that un-subscribes it" do
                poll_count = 0
                plan.add_permanent_task(task = task_m.new)
                handler = task.poll { poll_count += 1 }
                execute { task.start! }
                poll_count = 0
                handler.dispose
                execute_one_cycle
                assert_equal 0, poll_count
            end

            it "can be de-registered through the deprecated remove_poll_handler method" do
                poll_count = 0
                plan.add_permanent_task(task = task_m.new)
                handler = task.poll { poll_count += 1 }
                execute { task.start! }
                poll_count = 0
                task.remove_poll_handler(handler)
                execute_one_cycle
                assert_equal 0, poll_count
            end

            it "is called after the start handlers" do
                mock = flexmock

                task_m.on(:start) { |ev| mock.start_handler }
                task_m.poll { mock.poll_handler }

                plan.add_permanent_task(task = task_m.new)
                task.start_event.on { |ev| mock.start_handler }
                task.poll { |_| mock.poll_handler }
                mock.should_receive(:start_handler).twice.globally.ordered
                mock.should_receive(:poll_handler).at_least.twice.globally.ordered
                execute { task.start! }
            end

            it "is not called on pending tasks" do
                mock = flexmock

                task_m.poll { mock.poll_handler }
                plan.add(task = task_m.new)
                task.poll { |_| mock.poll_handler }

                mock.should_receive(:poll_handler).never
                expect_execution.to_run
            end

            it "is not called on finished tasks" do
                mock = flexmock

                task_m.poll { mock.poll_handler }
                plan.add(task = task_m.new)
                task.poll { |_| mock.poll_handler }

                mock.should_receive(:poll_handler).by_default
                expect_execution { task.start!; task.stop! }
                    .to { finish task }
                mock.should_receive(:poll_handler).never
                expect_execution.to_run
            end

            it "terminates a task if the block raises an exception" do
                mock = flexmock

                error_m = Class.new(RuntimeError)
                task_m.poll do
                    mock.polled(self)
                    raise error_m
                end

                plan.add_permanent_task(task = task_m.new)

                mock.should_receive(:polled).once
                expect_execution { task.start! }
                    .timeout(0)
                    .to do
                        have_handled_error_matching CodeError.match
                            .with_ruby_exception(error_m)
                        emit task.internal_error_event
                    end
            end

            it "stops the task using its own stop command" do
                mock = flexmock

                error_m = Class.new(RuntimeError)
                task_m.poll do
                    mock.polled(self)
                    raise error_m
                end
                task_m.event(:stop) { |ev| }

                plan.add_permanent_task(task = task_m.new)
                mock.should_receive(:polled).once
                expect_execution { task.start! }
                    .to do
                        emit task.internal_error_event
                        have_handled_error_matching error_m
                    end
                assert(task.failed?)
                assert(task.running?)
                assert(task.finishing?)
                plan.unmark_permanent_task(task)
                execute { task.stop_event.emit }
                assert(task.failed?)
                assert(!task.running?)
                assert(task.finished?)
            end
        end

        describe "#achieve_with" do
            it "emits the event if the slave succeeds" do
                plan.add(slave = Tasks::Simple.new)
                master = Task.new_submodel do
                    terminates
                    event :start do |context|
                        start_event.achieve_with slave
                    end
                end.new
                plan.add(master)

                execute { master.start! }
                assert(master.starting?)
                assert(master.depends_on?(slave))
                execute { slave.start! }
                execute { slave.success! }
                assert(master.started?)
            end

            it "fails the emission if the slave's success event becomes unreachable" do
                plan.add(slave = Tasks::Simple.new)
                master = Task.new_submodel do
                    event :start do |context|
                        start_event.achieve_with slave.start_event
                    end
                end.new
                plan.add(master)

                execute { master.start! }
                assert master.start_event.pending?
                execute { plan.remove_task(slave) }
                assert master.failed_to_start?
                assert_kind_of UnreachableEvent, master.failure_reason.error
                assert_equal slave.start_event, master.failure_reason.error.failed_generator
            end
        end

        describe "call and emission validity checks" do
            # We isolate call from emission by making the task's start event not
            # emit anything
            attr_reader :task, :task_m

            before do
                @task_m = Task.new_submodel { event(:start) { |context| } }
            end

            after do
                execute { task.start_event.emit } if task.start_event.pending?
            end

            def self.validity_checks_fail_at_toplevel(context, exception = TaskEventNotExecutable, *_)
                context.it "fails in #call" do
                    error = execute do
                        assert_raises(exception) do
                            task.start_event.call
                        end
                    end
                    assert_equal task.start_event, error.failure_point
                    assert_equal yield(true, task), error.message
                end
                context.it "fails in #emit" do
                    error = execute do
                        assert_raises(exception) do
                            task.start_event.emit
                        end
                    end
                    assert_equal task.start_event, error.failure_point
                    assert_equal yield(false, task), error.message
                end
            end

            def self.validity_checks_fail_during_propagation(
                context, exception = TaskEventNotExecutable, *
            )
                context.it "fails in #call_without_propagation" do
                    exception_matcher = exception.match.with_origin(task.start_event)
                    execution_exception =
                        expect_execution { task.start_event.call }
                        .to { have_error_matching exception_matcher }
                    assert_equal yield(true, task), execution_exception.exception.message
                end

                context.it "fails in #emit" do
                    error = execute do
                        assert_raises(exception) { task.start_event.emit }
                    end
                    assert_equal task.start_event, error.failure_point
                    assert_match yield(false, task), error.message
                end
            end

            describe "reporting of a finalized task" do
                before do
                    plan.add(@task = task_m.new)
                    execute { plan.remove_task(task) }
                end
                validity_checks_fail_at_toplevel(self, TaskEventNotExecutable) do |is_call, task|
                    "start_event.#{is_call ? 'call' : 'emit'} on #{task} but the task "\
                    "has been removed from its plan"
                end
            end

            describe "reporting of a task in a non-executable plan" do
                before do
                    @task = task_m.new
                end
                validity_checks_fail_at_toplevel(self, TaskEventNotExecutable) do |is_call, task|
                    "start_event.#{is_call ? 'call' : 'emit'} on #{task} but its plan is not executable"
                end
            end

            describe "reporting of an abstract task" do
                before do
                    plan.add(@task = task_m.new)
                    task.abstract = true
                end
                validity_checks_fail_during_propagation(self, TaskEventNotExecutable) do |is_call, task|
                    "start_event.#{is_call ? 'call' : 'emit'} on #{task} but the task is abstract"
                end
            end

            describe "reporting of a non-executable task" do
                before do
                    plan.add(@task = task_m.new)
                    task.executable = false
                end
                validity_checks_fail_during_propagation(self, TaskEventNotExecutable) do |is_call, task|
                    "start_event.#{is_call ? 'call' : 'emit'} on #{task} which is not executable"
                end
            end

            describe "reporting of a partially instanciated task" do
                before do
                    task_m = Task.new_submodel { argument :arg }
                    plan.add(@task = task_m.new)
                end
                validity_checks_fail_during_propagation(self, TaskEventNotExecutable) do |is_call, task|
                    "start_event.#{is_call ? 'call' : 'emit'} on #{task} which is partially instanciated\nThe following arguments were not set:\n  arg"
                end
            end

            describe "reporting a task whose start event is unreachable" do
                before do
                    plan.add(@task = task_m.new)
                    execute { task.start_event.unreachable! }
                end
                validity_checks_fail_at_toplevel(self, UnreachableEvent) do |is_call, task|
                    "#{is_call ? '#call' : '#emit'} called on #{task.start_event} which has been made unreachable"
                end
            end

            def exception_propagator(task, relation)
                first_task  = Tasks::Simple.new
                second_task = task
                first_task.start_event.send(relation, second_task.start_event)
                first_task.start!
            end
        end

        describe "#clear_relations" do
            attr_reader :task, :strong_graph, :ev
            before do
                strong_relation_m = Relations::Graph.new_submodel(strong: true)
                EventStructure.add_relation(strong_relation_m)
                plan.refresh_relations
                @strong_graph = plan.event_relation_graph_for(strong_relation_m)
                task_m = Tasks::Simple.new_submodel
                plan.add(@task = task_m.new)
                event_m = Roby::EventGenerator.new_submodel
                @ev = event_m.new
            end
            after do
                EventStructure.remove_relation(strong_graph.class)
                plan.refresh_relations
            end
            describe "remove_internal: false" do
                it "clears the external relations to the task's events" do
                    task.start_event.forward_to ev
                    ev.signals task.stop_event
                    assert task.clear_relations(remove_internal: false)
                    refute task.start_event.child_object?(ev, Roby::EventStructure::Forwarding)
                    refute task.stop_event.parent_object?(ev, Roby::EventStructure::Signal)
                    assert task.failed_event.child_object?(task.stop_event, Roby::EventStructure::Forwarding)
                end
                it "keeps strong relations with remove_strong: false" do
                    strong_graph.add_edge(task.start_event, ev, nil)
                    strong_graph.add_edge(ev, task.stop_event, nil)
                    refute task.clear_relations(remove_internal: false, remove_strong: false)
                    assert strong_graph.has_edge?(task.start_event, ev)
                    assert strong_graph.has_edge?(ev, task.stop_event)
                end
                it "removes strong relations with remove_strong: true" do
                    strong_graph.add_edge(task.start_event, ev, nil)
                    strong_graph.add_edge(ev, task.stop_event, nil)
                    assert task.clear_relations(remove_internal: false, remove_strong: true)
                    refute strong_graph.has_edge?(task.start_event, ev)
                    refute strong_graph.has_edge?(ev, task.stop_event)
                end
            end
            describe "remove_internal: true" do
                it "clears both internal and external relations involving the task's events" do
                    plan.add(ev = Roby::EventGenerator.new)
                    task.start_event.forward_to ev
                    ev.signals task.stop_event
                    assert task.clear_relations(remove_internal: true)
                    refute task.start_event.child_object?(ev, Roby::EventStructure::Forwarding)
                    refute task.stop_event.parent_object?(ev, Roby::EventStructure::Signal)
                    refute task.failed_event.child_object?(task.stop_event, Roby::EventStructure::Forwarding)
                end
                it "keeps strong relations with remove_strong: false" do
                    task.clear_relations(remove_internal: true) # Get a blank task
                    strong_graph.add_edge(task.start_event, ev, nil)
                    strong_graph.add_edge(ev, task.stop_event, nil)
                    strong_graph.add_edge(task.start_event, task.stop_event, nil)
                    refute task.clear_relations(remove_internal: false, remove_strong: false)
                    assert strong_graph.has_edge?(task.start_event, ev)
                    assert strong_graph.has_edge?(ev, task.stop_event)
                    assert strong_graph.has_edge?(task.start_event, task.stop_event)
                end
                it "removes strong relations with remove_strong: true" do
                    task.clear_relations(remove_internal: true) # Get a blank task
                    strong_graph.add_edge(task.start_event, ev, nil)
                    strong_graph.add_edge(ev, task.stop_event, nil)
                    strong_graph.add_edge(task.start_event, task.stop_event, nil)
                    assert task.clear_relations(remove_internal: true, remove_strong: true)
                    refute strong_graph.has_edge?(task.start_event, ev)
                    refute strong_graph.has_edge?(ev, task.stop_event)
                    refute strong_graph.has_edge?(task.start_event, task.stop_event)
                end
            end

            it "returns false if neither the bound events nor the task were involved in a relation" do
                refute task.clear_relations
            end
            it "returns true if the bound events were involved in a relation" do
                plan.add(ev = Roby::EventGenerator.new)
                task.start_event.forward_to ev
                assert task.clear_relations
            end
        end

        describe "#reusable?" do
            attr_reader :task
            before do
                task_m = Roby::Task.new_submodel do
                    event(:start) { |context| start_event.emit }
                    event(:stop) { |context| }
                end
                plan.add(@task = task_m.new)
            end
            after do
                execute { task.stop_event.emit } if task.running?
            end
            it "is true on new tasks" do
                assert task.reusable?
            end
            it "is false if #do_not_reuse has been called" do
                task.do_not_reuse
                assert !task.reusable?
            end
            it "is true on running tasks" do
                execute { task.start! }
                assert task.reusable?
            end
            it "is false on finishing tasks" do
                execute do
                    task.start!
                    task.stop!
                end
                refute task.reusable?
            end
            it "is false on finished tasks " do
                execute do
                    task.start!
                    task.stop_event.emit
                end
                refute task.reusable?
            end
            it "is false on finalized pending tasks" do
                execute { task.failed_to_start! "bla" }
                refute task.reusable?
            end
            it "is false on failed-to-start tasks" do
                execute { plan.remove_task(task) }
                refute task.reusable?
            end
            it "is false if the task is garbage" do
                execute { task.garbage! }
                refute task.reusable?
            end
            it "propagates a 'true' to a transaction proxy" do
                plan.in_transaction do |trsc|
                    assert trsc[task].reusable?
                end
            end
            it "propagates a 'false' to a transaction proxy" do
                task.do_not_reuse
                plan.in_transaction do |trsc|
                    refute trsc[task].reusable?
                end
            end
            it "propagates #do_not_reuse back from a proxy on commit" do
                plan.in_transaction do |trsc|
                    trsc[task].do_not_reuse
                    trsc.commit_transaction
                end
                refute task.reusable?
            end
            it "does not modify the underlying task's reusable flag from a transaction proxy" do
                plan.in_transaction do |trsc|
                    trsc[task].do_not_reuse
                    assert task.reusable?
                end
            end
            it "does not propagate #do_not_reuse back from a proxy on discard" do
                plan.in_transaction do |trsc|
                    trsc[task].do_not_reuse
                end
                assert task.reusable?
            end
        end

        describe "#garbage!" do
            it "marks its bound events as garbage" do
                plan.add(task = Tasks::Simple.new)
                execute { task.garbage! }
                assert task.start_event.garbage?
            end
        end

        describe "#mark_failed_to_start" do
            def self.nominal_behaviour(context)
                context.it "marks the task as failed_to_start?" do
                    task.mark_failed_to_start(flexmock, Time.now)
                    assert task.failed_to_start?
                end
                it "sets the failure time" do
                    task.mark_failed_to_start(flexmock, t = Time.now)
                    assert_equal t, task.failed_to_start_time
                end
                it "sets the failure reason" do
                    task.mark_failed_to_start(reason = flexmock, Time.now)
                    assert_equal reason, task.failure_reason
                end
                it "sets the task as failed in the index" do
                    task.mark_failed_to_start(reason = flexmock, Time.now)
                    assert_equal [task], plan.find_tasks.failed.to_a
                end
            end

            describe "pending tasks" do
                attr_reader :task
                before do
                    plan.add(@task = Tasks::Simple.new)
                end
                nominal_behaviour(self)
            end

            describe "starting tasks" do
                attr_reader :task
                before do
                    task_m = Roby::Task.new_submodel do
                        terminates
                        event(:start) { |_| }
                    end
                    plan.add(@task = task_m.new)
                    execute { task.start! }
                end
                nominal_behaviour(self)
            end

            describe "running tasks" do
                it "raises InternalError and does not mark the task" do
                    plan.add(task = Tasks::Simple.new)
                    execute { task.start! }
                    assert_raises(InternalError) do
                        task.mark_failed_to_start(flexmock, Time.now)
                    end
                    assert !task.failed_to_start?
                end
            end
        end

        describe "#handle_exception" do
            attr_reader :task_m, :localized_error_m, :recorder
            before do
                @task_m = Roby::Task.new_submodel
                @localized_error_m = Class.new(LocalizedError)
            end

            it "returns false if an exception handler calls #pass_exception" do
                recorder = flexmock
                task_m.on_exception(localized_error_m) do |exception|
                    recorder.called
                    pass_exception
                end
                plan.add(task = task_m.new)
                recorder.should_receive(:called).once
                refute task.handle_exception(localized_error_m.new(task).to_execution_exception)
            end

            it "processes handlers in inverse declaration order if one calls pass_exception" do
                recorder = flexmock
                task_m.on_exception(localized_error_m) do |exception|
                    recorder.called(1)
                end
                task_m.on_exception(localized_error_m) do |exception|
                    recorder.called(0)
                    pass_exception
                end
                plan.add(task = task_m.new)
                recorder.should_receive(:called).with(0).once.ordered
                recorder.should_receive(:called).with(1).once.ordered
                assert task.handle_exception(localized_error_m.new(task).to_execution_exception)
            end

            it "does not call a handler that do not match the exception object" do
                recorder = flexmock
                matcher = flexmock
                matcher.should_receive(:===)
                    .with(localized_error_m.to_execution_exception_matcher)
                    .and_return(false)
                matcher.should_receive(to_execution_exception_matcher: matcher)
                task_m.on_exception(matcher) do |exception|
                    recorder.called
                end
                recorder.should_receive(:called).never
                plan.add(task = task_m.new)
                refute task.handle_exception(localized_error_m.new(task).to_execution_exception)
            end
        end

        describe "#promise" do
            attr_reader :task
            before do
                plan.add(@task = Roby::Tasks::Simple.new)
            end
            it "raises if the task has failed to start" do
                execute { task.start_event.emit_failed }
                assert_raises(PromiseInFinishedTask) { task.promise {} }
            end
            it "raises if the task has finished" do
                execute { task.start! }
                execute { task.stop! }
                assert_raises(PromiseInFinishedTask) { task.promise {} }
            end
            it "creates a promise using the serialized task executor otherwise" do
                flexmock(execution_engine).should_receive(:promise).once
                    .with(->(h) { h[:executor].equal?(task.promise_executor) }, Proc)
                    .and_return(ret = flexmock)
                assert_equal(ret, task.promise {})
            end
        end
    end
end

class TC_Task < Minitest::Test
    def test_arguments_declaration
        model = Task.new_submodel { argument :from; argument :to }
        assert_equal([], Task.arguments.to_a)
        assert_equal(%i[from to].to_set, model.arguments.to_set)
    end

    def test_arguments_initialization
        model = Task.new_submodel { argument :arg; argument :to }
        plan.add(task = model.new(arg: "B"))
        assert_equal({ arg: "B" }, task.arguments)
        assert_equal("B", task.arg)
        assert_nil task.to
    end

    def test_arguments_initialization_uses_assignation_operator
        model = Task.new_submodel do
            argument :arg; argument :to
        end
        flexmock(model).new_instances.should_receive(:arg=).with("B").once.pass_thru

        plan.add(task = model.new(arg: "B"))
    end

    def test_meaningful_arguments
        model = Task.new_submodel { argument :arg }
        plan.add(task = model.new(arg: "B", useless: "bla"))
        assert_equal({ arg: "B", useless: "bla" }, task.arguments)
        assert_equal({ arg: "B" }, task.meaningful_arguments)
    end

    def test_meaningful_arguments_with_default_arguments
        child_model = Roby::Task.new_submodel do
            argument :start, default: 10
            argument :target
        end
        plan.add(child = child_model.new(target: 10))
        assert_equal({ target: 10 }, child.meaningful_arguments)
    end

    def test_arguments_partially_instanciated
        model = Task.new_submodel { argument :arg0; argument :arg1 }
        plan.add(task = model.new(arg0: "B", useless: "bla"))
        assert(task.partially_instanciated?)
        task.arg1 = "C"
        assert(!task.partially_instanciated?)
    end

    def test_command_block
        FlexMock.use do |mock|
            model = Tasks::Simple.new_submodel do
                event :start do |context|
                    mock.start(self, context)
                    start_event.emit
                end
            end
            plan.add_mission_task(task = model.new)
            mock.should_receive(:start).once.with(task, [42])
            execute { task.start!(42) }
        end
    end

    def test_command_inheritance
        FlexMock.use do |mock|
            parent_m = Tasks::Simple.new_submodel do
                event :start do |context|
                    mock.parent_started(self, context)
                    start_event.emit
                end
            end

            child_m = parent_m.new_submodel do
                event :start do |context|
                    mock.child_started(self, context.first)
                    super(context.first / 2)
                end
            end

            plan.add_mission_task(task = child_m.new)
            mock.should_receive(:parent_started).once.with(task, 21)
            mock.should_receive(:child_started).once.with(task, 42)
            execute { task.start!(42) }
        end
    end

    def assert_task_relation_set(task, relation, expected)
        plan.add(task)
        task.each_event do |from|
            task.each_event do |to|
                next if from == to

                exp = expected[from.symbol]
                if exp == to.symbol || (exp.respond_to?(:include?) && exp.include?(to.symbol))
                    assert from.child_object?(to, relation), "expected relation #{from} => #{to} in #{relation} is missing"
                else
                    assert !from.child_object?(to, relation), "unexpected relation #{from} => #{to} found in #{relation}"
                end
            end
        end
    end

    def do_test_instantiate_model_relations(method, relation, additional_links = {})
        klass = Roby::Tasks::Simple.new_submodel do
            4.times { |i| event "e#{i + 1}", command: true }
            send(method, e1: %i[e2 e3], e4: :stop)
        end

        plan.add(task = klass.new)
        expected_links = Hash[e1: %i[e2 e3], e4: :stop]

        assert_task_relation_set task, relation, expected_links.merge(additional_links)
    end

    def test_instantiate_model_signals
        do_test_instantiate_model_relations(:signal, EventStructure::Signal, internal_error: :stop)
    end

    def test_instantiate_model_forward
        do_test_instantiate_model_relations(:forward, EventStructure::Forwarding,
                                            success: :stop, aborted: :failed, failed: :stop)
    end

    def test_instantiate_model_causal_links
        do_test_instantiate_model_relations(:causal_link, EventStructure::CausalLink,
                                            internal_error: :stop, success: :stop, aborted: :failed, failed: :stop)
    end

    def do_test_inherit_model_relations(method, relation, additional_links = {})
        base = Roby::Tasks::Simple.new_submodel do
            4.times { |i| event "e#{i + 1}", command: true }
            send(method, e1: %i[e2 e3])
        end
        subclass = base.new_submodel do
            send(method, e4: :stop)
        end

        task = base.new
        assert_task_relation_set task, relation,
                                 Hash[e1: %i[e2 e3]].merge(additional_links)

        task = subclass.new
        assert_task_relation_set task, relation,
                                 Hash[e1: %i[e2 e3], e4: :stop].merge(additional_links)
    end

    def test_inherit_model_signals
        do_test_inherit_model_relations(:signal, EventStructure::Signal, internal_error: :stop)
    end

    def test_inherit_model_forward
        do_test_inherit_model_relations(:forward, EventStructure::Forwarding,
                                        success: :stop, aborted: :failed, failed: :stop)
    end

    def test_inherit_model_causal_links
        do_test_inherit_model_relations(:causal_link, EventStructure::CausalLink,
                                        internal_error: :stop, success: :stop, aborted: :failed, failed: :stop)
    end

    # Test the behaviour of Task#on, and event propagation inside a task
    def test_instance_event_handlers
        plan.add(t1 = Tasks::Simple.new)
        plan.add(task = Tasks::Simple.new)
        FlexMock.use do |mock|
            task.start_event.on   { |event| mock.started(event.context) }
            task.start_event.on   { |event| task.success_event.emit(*event.context) }
            task.success_event.on { |event| mock.success(event.context) }
            task.stop_event.on    { |event| mock.stopped(event.context) }
            mock.should_receive(:started).once.with([42]).ordered
            mock.should_receive(:success).once.with([42]).ordered
            mock.should_receive(:stopped).once.with([42]).ordered
            execute { task.start!(42) }
        end
        assert(task.finished?)
        event_history = task.history.map(&:generator)
        assert_equal([task.start_event, task.success_event, task.stop_event], event_history)
    end

    def test_instance_signals
        FlexMock.use do |mock|
            t1, t2 = prepare_plan add: 3, model: Tasks::Simple
            t1.start_event.signals t2.start_event

            t2.start_event.on { |ev| mock.start }
            mock.should_receive(:start).once
            execute { t1.start! }
        end
    end

    def test_instance_signals_plain_events
        t = prepare_plan missions: 1, model: Tasks::Simple
        e = EventGenerator.new(true)
        t.start_event.signals e
        execute { t.start! }
        assert(e.emitted?)
    end

    def test_model_forwardings
        model = Tasks::Simple.new_submodel do
            forward start: :failed
        end
        assert_equal({ start: %i[failed stop].to_set }, model.forwarding_sets)
        assert_equal({}, Tasks::Simple.signal_sets)

        assert_equal(%i[failed stop].to_set, model.forwardings(:start))
        assert_equal([:stop].to_set,          model.forwardings(:failed))
        assert_equal([:stop].to_set,          model.enum_for(:each_forwarding, :failed).to_set)

        plan.add(task = model.new)
        execute { task.start! }

        # Make sure the model-level relation is not applied to parent models
        plan.add(task = Tasks::Simple.new)
        execute { task.start! }
        assert(!task.failed?)
    end

    def test_instance_forward_to
        FlexMock.use do |mock|
            t1, t2 = prepare_plan missions: 2, model: Tasks::Simple
            t1.start_event.forward_to t2.start_event
            t2.start_event.on { |context| mock.start }

            mock.should_receive(:start).once
            execute { t1.start! }
        end
    end

    def test_instance_forward_to_plain_events
        FlexMock.use do |mock|
            t1 = prepare_plan missions: 1, model: Tasks::Simple
            ev = EventGenerator.new do
                mock.called
                ev.emit
            end
            ev.on { |event| mock.emitted }
            t1.start_event.forward_to ev

            mock.should_receive(:called).never
            mock.should_receive(:emitted).once
            execute { t1.start! }
        end
    end

    def test_terminal_option
        klass = Task.new_submodel do
            event :terminal, terminal: true
        end
        assert klass.event_model(:terminal).terminal?
        plan.add(task = klass.new)
        assert task.event(:terminal).terminal?
        assert task.event(:terminal).child_object?(task.stop_event, EventStructure::Forwarding)
    end

    ASSERT_EVENT_ALL_PREDICATES = %i[terminal? failure? success?].freeze
    ASSERT_EVENT_PREDICATES = {
        normal: [],
        stop: [:terminal?],
        failed: %i[terminal? failure?],
        success: %i[terminal? success?]
    }.freeze

    def assert_model_event_flag(model, event_name, model_flag)
        if model_flag != :normal
            assert model.event_model(event_name).terminal?, "#{model}.#{event_name}.terminal? returned false"
        else
            assert !model.event_model(event_name).terminal?, "#{model}.#{event_name}.terminal? returned true"
        end
    end

    def assert_event_flag(task, event_name, instance_flag, model_flag)
        ASSERT_EVENT_PREDICATES.fetch(instance_flag).each do |pred|
            assert task.event(event_name).send(pred), "#{task}.#{event_name}.#{pred} returned false"
        end
        (ASSERT_EVENT_ALL_PREDICATES - ASSERT_EVENT_PREDICATES[instance_flag]).each do |pred|
            assert !task.event(event_name).send(pred), "#{task}.#{event_name}.#{pred} returned true"
        end
        assert_model_event_flag(task, event_name, model_flag)
    end

    def test_terminal_forward_stop(target_event = :stop)
        klass = Task.new_submodel do
            event :direct
            event :indirect
            event :intermediate
        end
        plan.add(task = klass.new)
        task.direct_event.forward_to task.event(target_event)
        task.indirect_event.forward_to task.intermediate_event
        task.intermediate_event.forward_to task.event(target_event)
        assert_event_flag(task, :direct, target_event, :normal)
        assert_event_flag(task, :indirect, target_event, :normal)
    end

    def test_terminal_forward_success
        test_terminal_forward_stop(:success)
    end

    def test_terminal_forward_failed
        test_terminal_forward_stop(:failed)
    end

    def test_terminal_forward_stop_in_model(target_event = :stop, flag: target_event)
        klass = Task.new_submodel do
            event :terminal_e, terminal: true

            event :direct
            forward direct: target_event

            event :indirect
            event :intermediate
            forward indirect: :intermediate
            forward intermediate: target_event
        end
        assert_model_event_flag(klass, :direct, target_event)
        assert_model_event_flag(klass, :indirect, target_event)
        plan.add(task = klass.new)
        assert_event_flag(task, :direct, flag, flag)
        assert_event_flag(task, :indirect, flag, flag)
    end

    def test_terminal_forward_success_in_model
        test_terminal_forward_stop_in_model(:success)
    end

    def test_terminal_forward_failed_in_model
        test_terminal_forward_stop_in_model(:failed)
    end

    def test_terminal_forward_terminal_e_in_model
        test_terminal_forward_stop_in_model(:terminal_e, flag: :stop)
    end

    def test_terminal_signal_stop(target_event = :stop, flag: target_event)
        klass = Task.new_submodel do
            event :direct

            event :indirect
            event :intermediate, controlable: true
            event target_event, controlable: true, terminal: true
        end
        plan.add(task = klass.new)
        task.direct_event.signals task.event(target_event)
        task.indirect_event.signals task.intermediate_event
        task.intermediate_event.signals task.event(target_event)
        assert_event_flag(task, :direct, flag, :normal)
        assert_event_flag(task, :indirect, flag, :normal)
    end

    def test_terminal_signal_success
        test_terminal_signal_stop(:success)
    end

    def test_terminal_signal_failed
        test_terminal_signal_stop(:failed)
    end

    def test_terminal_event_is_terminal
        klass = Task.new_submodel do
            event :terminal_e, controlable: true, terminal: true
        end
        plan.add(task = klass.new)
        assert task.terminal_e_event.terminal?
        assert_event_flag(task, :terminal_e, :stop, :stop)
    end

    def test_terminal_signal_stop_in_model(target_event = :stop, flag: target_event)
        klass = Task.new_submodel do
            event :direct

            event :indirect
            event :intermediate, controlable: true
            event target_event, controlable: true, terminal: true

            signal direct: target_event
            signal indirect: :intermediate
            signal intermediate: target_event
        end
        assert_model_event_flag(klass, :direct, target_event)
        assert_model_event_flag(klass, :indirect, target_event)
        plan.add(task = klass.new)
        assert_event_flag(task, :direct, flag, flag)
        assert_event_flag(task, :indirect, flag, flag)
    end

    def test_terminal_signal_success_in_model
        test_terminal_signal_stop_in_model(:success)
    end

    def test_terminal_signal_failed_in_model
        test_terminal_signal_stop_in_model(:failed)
    end

    def test_terminal_signal_terminal_e_in_model
        test_terminal_signal_stop_in_model(:terminal_e, flag: :stop)
    end

    def test_terminal_alternate_stop(target_event = :stop)
        klass = Task.new_submodel do
            event :forward_first
            event :intermediate_signal
            event target_event, controlable: true, terminal: true

            event :signal_first
            event :intermediate_forward, controlable: true
        end
        assert_model_event_flag(klass, :signal_first, :normal)
        assert_model_event_flag(klass, :forward_first, :normal)
        plan.add(task = klass.new)

        task.forward_first_event.forward_to task.event(:intermediate_signal)
        task.intermediate_signal_event.signals task.event(target_event)
        task.signal_first_event.signals task.event(:intermediate_forward)
        task.intermediate_forward_event.forward_to task.event(target_event)
        assert_event_flag(task, :signal_first, target_event, :normal)
        assert_event_flag(task, :forward_first, target_event, :normal)
    end

    def test_terminal_alternate_success
        test_terminal_signal_stop(:success)
    end

    def test_terminal_alternate_failed
        test_terminal_signal_stop(:failed)
    end

    def test_terminal_alternate_stop_in_model(target_event = :stop)
        klass = Task.new_submodel do
            event :forward_first
            event :intermediate_signal
            event target_event, controlable: true, terminal: true

            event :signal_first
            event :intermediate_forward, controlable: true

            forward forward_first: :intermediate_signal
            signal  intermediate_signal: target_event
            signal signal_first: :intermediate_forward
            forward intermediate_forward: target_event
        end
        assert_model_event_flag(klass, :signal_first, target_event)
        assert_model_event_flag(klass, :forward_first, target_event)
        plan.add(task = klass.new)
        assert_event_flag(task, :signal_first, target_event, target_event)
        assert_event_flag(task, :forward_first, target_event, target_event)
    end

    def test_terminal_alternate_success_in_model
        test_terminal_signal_stop_in_model(:success)
    end

    def test_terminal_alternate_failed_in_model
        test_terminal_signal_stop_in_model(:failed)
    end

    def test_should_not_establish_signal_from_terminal_to_non_terminal
        klass = Task.new_submodel do
            event :terminal, terminal: true
            event :intermediate
        end
        assert_raises(ArgumentError) { klass.forward terminal: :intermediate }
        klass.new
    end

    # Tests Task::event
    def test_event_declaration
        klass = Task.new_submodel do
            # For rubocop
            class_eval do
                def ev_not_controlable; end

                def ev_method(event = :ev_method)
                    :ev_method if event == :ev_redirected
                end
            end

            event :ev_contingent
            event :ev_controlable do |*events|
                :ev_controlable
            end

            event :ev_not_controlable
            event :ev_redirected,
                  command: ->(task, event, *) { task.ev_method(event) }
        end

        klass.event :ev_terminal, terminal: true, command: true

        plan.add(task = klass.new)
        assert_respond_to(task, :start!)
        assert_respond_to(task, :start?)

        # Test modifications to the class hierarchy
        my_event = nil
        my_event = klass.const_get(:EvContingent)
        assert_raises(NameError) { klass.superclass.const_get(:EvContingent) }
        assert_equal(TaskEvent, my_event.superclass)
        assert_equal(:ev_contingent, my_event.symbol)
        assert(klass.has_event?(:ev_contingent))

        my_event = klass.const_get(:EvTerminal)
        assert_equal(:ev_terminal, my_event.symbol)

        # Check properties on EvContingent
        assert(!klass::EvContingent.respond_to?(:call))
        assert(!klass::EvContingent.controlable?)
        assert(!klass::EvContingent.terminal?)

        # Check properties on EvControlable
        assert(klass::EvControlable.controlable?)
        assert(klass::EvControlable.respond_to?(:call))
        event = klass::EvControlable.new(task, task.ev_controlable_event, 0, nil)
        assert_equal(:ev_controlable, klass::EvControlable.call(task, :ev_controlable))

        # Check Event.terminal? if terminal: true
        assert(klass::EvTerminal.terminal?)

        # Check controlable: [proc] behaviour
        assert(klass::EvRedirected.controlable?)

        # Check that command: false disables controlable?
        assert(!klass::EvNotControlable.controlable?)

        # Check validation of options[:command]
        assert_raises(ArgumentError) { klass.event :try_event, command: "bla" }

        plan.add(task = EmptyTask.new)
        start_event = task.start_event

        assert_equal(start_event, task.start_event)
        assert_equal([], start_event.handlers)
        # Note that the start => stop forwarding is added because 'start' is
        # detected as terminal in the EmptyTask model
        assert_equal([task.stop_event, task.success_event].to_set, start_event.enum_for(:each_forwarding).to_set)
        start_model = task.event_model(:start)
        assert_equal(start_model, start_event.event_model)
        assert_equal(%i[stop success].to_set, task.model.enum_for(:each_forwarding, :start).to_set)
    end

    def test_context_propagation
        FlexMock.use do |mock|
            model = Tasks::Simple.new_submodel do
                event :start do |context|
                    mock.starting(context)
                    start_event.emit(*context)
                end
                on(:start) do |event|
                    mock.started(event.context)
                end

                event :pass_through, command: true
                on(:pass_through) do |event|
                    mock.pass_through(event.context)
                end

                on(:stop) { |event| mock.stopped(event.context) }
            end
            plan.add_mission_task(task = model.new)

            mock.should_receive(:starting).with([42]).once
            mock.should_receive(:started).with([42]).once
            mock.should_receive(:pass_through).with([10]).once
            mock.should_receive(:stopped).with([21]).once
            execute do
                task.start!(42)
                task.pass_through!(10)
                task.stop_event.emit(21)
            end
            assert(task.finished?)
        end
    end

    def test_inheritance_overloading
        base = Roby::Task.new_submodel
        base.event :ctrl, command: true
        base.event :stop
        assert(!base.find_event_model(:stop).controlable?)

        sub = base.new_submodel
        sub.event :start, command: true
        assert_raises(ArgumentError) { sub.event :ctrl, command: false }
        assert_raises(ArgumentError) { sub.event :failed, terminal: false }
        assert_raises(ArgumentError) { sub.event :failed }

        sub.event(:stop) { |context| }
        assert(sub.find_event_model(:stop).controlable?)

        sub = base.new_submodel
        sub.start_event { |context| }
    end

    def test_singleton
        model = Task.new_submodel do
            # For rubocop
            class_eval do
                def initialize
                    singleton_class.event(:start, command: true)
                    singleton_class.stop_event
                    super
                end
            end
            event :inter
        end

        ev_models = Hash[*model.enum_for(:each_event).to_a.flatten]
        assert_equal(%i[start success aborted internal_error updated_data stop failed inter poll_transition].to_set, ev_models.keys.to_set)

        plan.add(task = model.new)
        ev_models = Hash[*task.model.enum_for(:each_event).to_a.flatten]
        assert_equal(%i[start success aborted internal_error updated_data stop failed inter poll_transition].to_set, ev_models.keys.to_set)
        assert ev_models[:start].symbol
        assert ev_models[:start].name || !ev_models[:start].name.empty?
    end

    def test_finished
        model = Roby::Task.new_submodel do
            event :start, command: true
            event :failed, command: true, terminal: true
            event :success, command: true, terminal: true
            event :stop, command: true
        end

        plan.add(task = model.new)
        execute { task.start! }
        execute { task.stop_event.emit }
        assert(!task.success?)
        assert(!task.failed?)
        assert(task.finished?)
        assert_equal(task.stop_event.last, task.terminal_event)

        plan.add(task = model.new)
        execute { task.start! }
        execute { task.success_event.emit }
        assert(task.success?)
        assert(!task.failed?)
        assert(task.finished?)
        assert_equal(task.success_event.last, task.terminal_event)

        plan.add(task = model.new)
        execute { task.start! }
        execute { task.failed_event.emit }
        assert(!task.success?)
        assert(task.failed?)
        assert(task.finished?)
        assert_equal(task.failed_event.last, task.terminal_event)
    end

    def assert_exception_message(klass, msg)
        yield
        flunk "no exception raised"
    rescue klass => e
        unless msg === e.message
            flunk "exception message '#{e.message}' does not match the expected pattern #{msg}"
        end
    rescue Exception => e
        flunk "expected an exception of class #{klass} but got #{e.full_message}"
    end

    def test_cannot_start_if_not_executable
        model = Tasks::Simple.new_submodel do
            event(:inter, command: true)

            # For rubocop
            class_eval do
                def executable?
                    false
                end
            end
        end

        plan.add(task = model.new)
        expect_execution { task.start_event.call }
            .to { have_error_matching EventNotExecutable.match.with_origin(task.start_event) }

        plan.add(task = model.new)
        expect_execution { task.start! }
            .to { have_error_matching EventNotExecutable.match.with_origin(task.start_event) }
    end

    def test_executable
        model = Tasks::Simple.new_submodel do
            event(:inter, command: true)
        end
        task = model.new

        assert(!task.executable?)
        assert(!task.start_event.executable?)
        task.executable = true
        assert(task.executable?)
        assert(task.start_event.executable?)
        task.executable = nil
        assert(!task.executable?)
        assert(!task.start_event.executable?)

        plan.add(task)
        assert(task.executable?)
        assert(task.start_event.executable?)
        task.executable = false
        assert(!task.executable?)
        assert(!task.start_event.executable?)
        task.executable = nil
        assert(task.executable?)
        assert(task.start_event.executable?)

        # Cannot change the flag if the task is running
        task.executable = nil
        execute { task.start! }
        assert_raises(ModelViolation) { task.executable = false }
    end

    def test_task_success_failure
        FlexMock.use do |mock|
            plan.add_mission_task(t = EmptyTask.new)
            %i[start success stop].each do |name|
                t.event(name).on { |event| mock.send(name) }
                mock.should_receive(name).once.ordered
            end
            execute { t.start! }
        end
    end

    def aggregator_test(a, *tasks)
        plan.add_mission_task(a)
        FlexMock.use do |mock|
            %i[start success stop].each do |name|
                a.event(name).on { |ev| mock.send(name) }
                mock.should_receive(name).once.ordered
            end
            execute { a.start! }
            assert(tasks.all?(&:finished?))
        end
    end

    def test_task_parallel_aggregator
        t1, t2 = EmptyTask.new, EmptyTask.new
        plan.add([t1, t2])
        aggregator_test((t1 | t2), t1, t2)
        t1, t2 = EmptyTask.new, EmptyTask.new
        plan.add([t1, t2])
        aggregator_test((t1 | t2).to_task, t1, t2)
    end

    def task_tuple(count)
        tasks = (1..count).map do
            t = EmptyTask.new
            t.executable = true
            t
        end
        yield(tasks)
    end

    def test_sequence
        task_tuple(2) { |t1, t2| aggregator_test((t1 + t2), t1, t2) }
        task_tuple(2) do |t1, t2|
            s = t1 + t2
            aggregator_test(s.to_task, t1, t2)
            assert(!t1.stop_event.related_object?(s.stop_event, EventStructure::Precedence))
        end

        task_tuple(3) do |t1, t2, t3|
            s = t2 + t3
            s.unshift t1
            aggregator_test(s, t1, t2, t3)
        end

        task_tuple(3) do |t1, t2, t3|
            s = t2 + t3
            s.unshift t1
            aggregator_test(s.to_task, t1, t2, t3)
        end
    end

    def test_sequence_child_of
        model = Tasks::Simple.new_submodel
        t1, t2 = prepare_plan tasks: 2, model: Tasks::Simple

        seq = (t1 + t2)
        assert(seq.child_object?(t1, TaskStructure::Dependency))
        assert(seq.child_object?(t2, TaskStructure::Dependency))

        task = seq.child_of(model)
        assert !seq.plan

        plan.add_mission_task(task)

        execute { task.start! }
        assert(t1.running?)
        execute { t1.success! }
        assert(t2.running?)
        execute { t2.success! }
        assert(task.success?)
    end

    def test_compatible_state
        t1, t2 = prepare_plan add: 2, model: Tasks::Simple

        assert(t1.compatible_state?(t2))
        execute { t1.start! }
        assert(!t1.compatible_state?(t2) && !t2.compatible_state?(t1))
        execute { t1.stop! }
        assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))

        plan.add(t1 = Tasks::Simple.new)
        execute { t1.start! }
        execute { t2.start! }
        assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))
        execute { t1.stop! }
        assert(t1.compatible_state?(t2) && !t2.compatible_state?(t1))
    end

    def test_fullfills
        abstract_task_model = TaskService.new_submodel do
            argument :abstract
        end
        task_model = Task.new_submodel do
            include abstract_task_model
            argument :index; argument :universe
        end

        t1, t2 = task_model.new, task_model.new
        plan.add([t1, t2])
        assert(t1.fullfills?(t1.model))
        assert(t1.fullfills?(t2))
        assert(t1.fullfills?(abstract_task_model))

        plan.add(t2 = task_model.new(index: 2))
        assert(!t1.fullfills?(t2))

        plan.add(t3 = task_model.new(universe: 42))
        assert(t3.fullfills?(t1))
        assert(!t1.fullfills?(t3))
        plan.add(t3 = task_model.new(universe: 42, index: 21))
        assert(t3.fullfills?(task_model, universe: 42))

        plan.add(t3 = Task.new_submodel.new)
        assert(!t1.fullfills?(t3))

        plan.add(t3 = task_model.new_submodel.new)
        assert(!t1.fullfills?(t3))
        assert(t3.fullfills?(t1))
    end

    def test_fullfill_using_explicit_fullfilled_model_on_task_model
        tag = TaskService.new_submodel
        proxy_model = Task.new_submodel do
            include tag
        end
        proxy_model.fullfilled_model = [tag]
        real_model = Task.new_submodel do
            include tag
        end

        t1, t2 = real_model.new, proxy_model.new
        assert(t1.fullfills?(t2))
        assert(t1.fullfills?([t2]))
        assert(t1.fullfills?(tag))
    end

    def test_related_tasks
        t1, t2, t3 = (1..3).map { Tasks::Simple.new }
            .each { |t| plan.add(t) }
        t1.depends_on t2
        t1.start_event.signals t3.start_event
        assert_equal([t3].to_set, t1.start_event.related_tasks)
        assert_equal([t2].to_set, t1.related_objects)
        assert_equal([t2, t3].to_set, t1.related_tasks)
    end

    def test_related_events
        t1, t2, t3 = (1..3).map { Tasks::Simple.new }
            .each { |t| plan.add(t) }
        t1.depends_on t2
        t1.start_event.signals t3.start_event
        assert_equal([t3.start_event].to_set, t1.related_events)
    end

    def test_if_unreachable
        model = Tasks::Simple.new_submodel do
            event :ready
        end

        # Test that the stop event will make the handler called on a running task
        FlexMock.use do |mock|
            plan.add(task = model.new)
            ev = task.success_event
            ev.if_unreachable(cancel_at_emission: false) { mock.success_called }
            ev.if_unreachable(cancel_at_emission: true)  { mock.success_cancel_called }
            mock.should_receive(:success_called).once
            mock.should_receive(:success_cancel_called).never
            ev = task.ready_event
            ev.if_unreachable(cancel_at_emission: false) { mock.ready_called }
            ev.if_unreachable(cancel_at_emission: true)  { mock.ready_cancel_called }
            mock.should_receive(:ready_called).once
            mock.should_receive(:ready_cancel_called).once

            execute do
                task.start!
                task.success!
            end
        end
        execute { execution_engine.garbage_collect }

        # Test that it works on pending tasks too
        FlexMock.use do |mock|
            plan.add(task = model.new)
            ev = task.success_event
            ev.if_unreachable(cancel_at_emission: false) { mock.success_called }
            ev.if_unreachable(cancel_at_emission: true)  { mock.success_cancel_called }
            mock.should_receive(:success_called).once
            mock.should_receive(:success_cancel_called).once

            ev = task.ready_event
            ev.if_unreachable(cancel_at_emission: false) { mock.ready_called }
            ev.if_unreachable(cancel_at_emission: true)  { mock.ready_cancel_called }
            mock.should_receive(:ready_called).once
            mock.should_receive(:ready_cancel_called).once

            execute { execution_engine.garbage_collect }
        end
    end

    def test_stop_becomes_unreachable
        FlexMock.use do |mock|
            plan.add(task = Roby::Tasks::Simple.new)
            ev = task.stop_event
            ev.if_unreachable(cancel_at_emission: false) { mock.stop_called }
            ev.if_unreachable(cancel_at_emission: true)  { mock.stop_cancel_called }

            mock.should_receive(:stop_called).once
            mock.should_receive(:stop_cancel_called).never
            execute { task.start! }
            execute { task.stop! }
        end
    end

    def test_task_group
        t1, t2 = Tasks::Simple.new, Tasks::Simple.new
        plan.add(g = Tasks::Group.new(t1, t2))

        execute { g.start! }
        assert(t1.running?)
        assert(t2.running?)

        execute { t1.success! }
        assert(g.running?)
        execute { t2.success! }
        assert(g.success?)
    end

    def test_events_emitted_multiple_times_in_the_same_cycle_cause_only_one_handler_to_be_called
        mock = flexmock

        task_m = Tasks::Simple.new_submodel do
            poll do
                mock.polled(self)
                internal_error_event.emit
                internal_error_event.emit
            end
            on :internal_error do |ev|
                mock.emitted
            end
        end

        plan.add(t = task_m.new)
        mock.should_receive(:polled).once
        mock.should_receive(:emitted).once
        expect_execution { t.start! }
            .to { emit t.internal_error_event }
    end

    def test_event_task_sources
        task = Tasks::Simple.new_submodel do
            event :specialized_failure, command: true
            forward specialized_failure: :failed
        end.new
        plan.add(task)

        execute { task.start! }
        assert_equal([], task.start_event.last.task_sources.to_a)

        ev = EventGenerator.new(true)
        ev.forward_to task.specialized_failure_event
        execute { ev.call }
        assert_equal([task.failed_event.last], task.stop_event.last.task_sources.to_a)
        assert_equal([task.specialized_failure_event.last, task.failed_event.last].to_set, task.stop_event.last.all_task_sources.to_set)
    end

    def test_dup
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
        end
        plan.add(task = model.new)
        execute { task.start! }
        execute { task.intermediate_event.emit }

        new = task.dup
        assert !new.find_event(:stop)

        assert(!plan.has_task?(new))

        assert_kind_of(Roby::TaskArguments, new.arguments)
        assert_equal(task.arguments.to_hash, new.arguments.to_hash)

        assert(task.running?)
        assert(new.running?)
    end

    def test_failed_to_start
        plan.add(task = Roby::Test::Tasks::Simple.new)
        execute { task.failed_to_start!("test") }
        assert task.failed_to_start?
        assert_equal "test", task.failure_reason
        assert task.failed?
        assert !task.pending?
        assert !task.running?
        assert_equal [], plan.find_tasks.pending.to_a
        assert_equal [], plan.find_tasks.running.to_a
        assert_equal [task], plan.find_tasks.failed.to_a
    end

    def test_cannot_call_event_on_task_that_failed_to_start
        plan.add(task = Roby::Test::Tasks::Simple.new)
        execute { task.failed_to_start!("test") }
        assert task.plan
        assert task.failed_to_start?
        execute do
            assert_raises(Roby::CommandRejected) { task.stop! }
        end
    end

    def test_cannot_call_event_on_task_that_finished
        plan.add(task = Roby::Test::Tasks::Simple.new)
        execute { task.start_event.emit }
        execute { task.stop_event.emit }
        execute do
            assert_raises(Roby::CommandRejected) { task.stop! }
        end
    end

    def test_intermediate_emit_failed
        model = Tasks::Simple.new_submodel { event :intermediate }

        plan.add(task = model.new)
        expect_execution do
            task.start!
            task.intermediate_event.emit_failed
        end.to do
            have_handled_error_matching EmissionFailed.match
                .with_origin(task.intermediate_event)
                .with_ruby_exception(nil)
            emit task.internal_error_event
        end
        assert task.internal_error?
        assert task.failed?
        assert_kind_of EmissionFailed, task.failure_reason
        assert_equal task.intermediate_event, task.failure_reason.failed_generator
    end

    def test_emergency_termination_fails
        model = Tasks::Simple.new_submodel do
            event :command_fails do |context|
                raise ArgumentError
            end
            event :emission_fails
        end
        plan.add(task = model.new)
        expect_execution do
            task.start!
            task.command_fails!
        end.to do
            have_handled_error_matching CommandFailed.match
                .with_origin(task.command_fails_event)
            emit task.internal_error_event
        end

        assert(task.internal_error?)
        assert(task.failed?)
        assert_kind_of CommandFailed, task.failure_reason
        assert_equal(task.command_fails_event, task.failure_reason.failed_generator)

        plan.add(task = model.new)
        expect_execution do
            task.start!
            task.emission_fails_event.emit_failed
        end.to do
            have_handled_error_matching EmissionFailed.match
                .with_origin(task.emission_fails_event)
                .with_ruby_exception(nil)
            emit task.internal_error_event
        end

        assert(task.failed?)
        assert_kind_of EmissionFailed, task.failure_reason
    end

    def test_emergency_termination_in_terminal_commands
        mock = flexmock
        mock.should_expect do |m|
            m.cmd_stop.once.ordered
            m.cmd_failed.once.ordered
        end

        model = Tasks::Simple.new_submodel do
            event :failed, terminal: true do |context|
                mock.cmd_failed
                raise ArgumentError
            end
            event :stop, terminal: true do |context|
                mock.cmd_stop
                failed!
            end
        end
        plan.add(task = model.new)
        capture_log(execution_engine, :fatal) do
            expect_execution do
                task.start!
                task.stop!
            end.to do
                have_error_matching Roby::TaskEmergencyTermination
                quarantine task
            end
        end
    ensure
        if task
            task.forcefully_terminate
            execute { plan.remove_task(task) }
        end
    end

    def test_nil_default_argument
        model = Tasks::Simple.new_submodel do
            argument "value", default: nil
        end
        task = model.new
        assert task.fully_instanciated?
        assert !task.arguments.static?
        plan.add(task)
        assert task.executable?
        execute { task.start! }
        assert_nil task.arguments[:value]
    end

    def test_plain_default_argument
        model = Tasks::Simple.new_submodel do
            argument "value", default: 10
        end
        task = model.new
        assert task.fully_instanciated?
        assert !task.arguments.static?
        plan.add(task)
        assert task.executable?
        execute { task.start! }
        assert_equal 10, task.arguments[:value]
    end

    def test_delayed_argument_from_task
        value_obj = Class.new do
            attr_accessor :value
        end.new

        klass = Roby::Task.new_submodel do
            terminates
            argument :arg, default: from(:planned_task).arg.of_type(Numeric)
        end

        planning_task = klass.new
        planned_task  = klass.new
        planned_task.planned_by planning_task
        plan.add(planned_task)

        assert !planning_task.arguments.static?
        assert !planning_task.fully_instanciated?
        planned_task.arg = Object.new
        assert !planning_task.fully_instanciated?
        plan.force_replace_task(planned_task, (planned_task = klass.new))
        planned_task.arg = 10
        assert planning_task.fully_instanciated?
        execute { planning_task.start! }
        assert_equal 10, planning_task.arg
    end

    def test_delayed_argument_from_object
        value_obj = Class.new do
            attr_accessor :value
        end.new

        klass = Roby::Task.new_submodel do
            terminates
            argument :arg
        end
        task = klass.new(arg: Roby.from(value_obj).value.of_type(Integer))
        plan.add(task)

        assert !task.arguments.static?
        assert !task.fully_instanciated?
        value_obj.value = 10
        assert task.fully_instanciated?
        assert_nil task.arg
        value_obj.value = 20
        execute { task.start! }
        assert_equal 20, task.arg
    end

    def test_can_merge_model
        test_model1 = Roby::Task.new_submodel
        test_model2 = Roby::Task.new_submodel
        test_model3 = test_model1.new_submodel

        t1 = test_model1.new
        t2 = test_model2.new
        t3 = test_model3.new

        assert(t1.can_merge?(t1))
        assert(t3.can_merge?(t1))
        assert(!t1.can_merge?(t3))
        assert(!t1.can_merge?(t2))

        assert(!t3.can_merge?(t2))
        assert(!t2.can_merge?(t3))
    end

    def test_can_merge_arguments
        test_model = Roby::Task.new_submodel do
            argument :id
        end
        t1 = test_model.new
        t2 = test_model.new

        assert(t1.can_merge?(t2))
        assert(t2.can_merge?(t1))

        t2.arguments[:id] = 10
        assert(t1.can_merge?(t2))
        assert(t2.can_merge?(t1))

        t1.arguments[:id] = 20
        assert(!t1.can_merge?(t2))
        assert(!t2.can_merge?(t1))
    end

    def test_execute_handlers_with_replacing
        model = Roby::Task.new_submodel do
            terminates
        end
        old, new = prepare_plan missions: 2, model: model

        FlexMock.use do |mock|
            old.execute { |task| mock.should_not_be_passed_on(task) }
            old.execute(on_replace: :copy) { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)

            assert_equal(1, new.execute_handlers.size)
            assert_equal(new.execute_handlers[0].block, old.execute_handlers[1].block)

            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once

            expect_execution { old.start!; new.start! }.to_run
        end
    end

    def test_poll_handlers_with_replacing
        model = Roby::Task.new_submodel do
            terminates
        end
        old, new = prepare_plan missions: 2, model: model

        FlexMock.use do |mock|
            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once
            old.poll { |task| mock.should_not_be_passed_on(task) }
            old.poll(on_replace: :copy) { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)

            assert_equal(1, new.poll_handlers.size)
            assert_equal(new.poll_handlers[0].block, old.poll_handlers[1].block)

            execute do
                old.start!
                new.start!
            end
        end
    end

    def test_poll_is_called_while_the_task_is_running
        test_case = self
        model = Roby::Task.new_submodel do
            terminates

            poll do
                test_case.assert running?
            end
        end
        plan.add(task = model.new)
        execute { task.start! }
    end

    def test_event_handlers_with_replacing
        model = Roby::Task.new_submodel do
            terminates
        end
        old, new = prepare_plan missions: 2, model: model

        FlexMock.use do |mock|
            mock.should_receive(:should_be_passed_on).with(new).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_not_be_passed_on).with(old).once

            old.start_event.on { |event| mock.should_not_be_passed_on(event.task) }
            old.start_event.on(on_replace: :copy) { |event| mock.should_be_passed_on(event.task) }

            plan.replace(old, new)

            assert_equal(1, new.start_event.handlers.size)
            assert_equal(new.start_event.handlers[0].block, old.start_event.handlers[1].block)

            execute { old.start! }
            execute { new.start! }
        end
    end

    def test_abstract_tasks_automatically_mark_the_poll_handlers_as_replaced
        abstract_model = Roby::Task.new_submodel { abstract }
        concrete_model = abstract_model.new_submodel { terminates }
        plan.add_permanent_task(old = abstract_model.new)
        plan.add_permanent_task(new = concrete_model.new)

        FlexMock.use do |mock|
            mock.should_receive(:should_be_passed_on).with(new).once

            old.poll { |task| mock.should_be_passed_on(task) }
            old.poll(on_replace: :drop) { |task| mock.should_not_be_passed_on(task) }

            plan.replace(old, new)

            assert_equal(1, new.poll_handlers.size, new.poll_handlers.map(&:block))
            assert_equal(new.poll_handlers[0].block, old.poll_handlers[0].block)

            expect_execution { new.start! }.to_run
        end
    end

    def test_abstract_tasks_automatically_mark_the_event_handlers_as_replaced
        abstract_model = Roby::Task.new_submodel { abstract }
        concrete_model = abstract_model.new_submodel { terminates }
        plan.add_mission_task(old = abstract_model.new)
        plan.add_mission_task(new = concrete_model.new)

        FlexMock.use do |mock|
            old.start_event.on { |event| mock.should_be_passed_on(event.task) }
            old.start_event.on(on_replace: :drop) { |event| mock.should_not_be_passed_on(event.task) }

            plan.replace(old, new)
            assert_equal(1, new.start_event.handlers.size)
            assert_equal(new.start_event.handlers[0].block, old.start_event.handlers[0].block)

            mock.should_receive(:should_not_be_passed_on).never
            mock.should_receive(:should_be_passed_on).with(new).once
            execute { new.start! }
        end
    end

    def test_finalization_handlers_with_replacing
        model = Roby::Task.new_submodel do
            terminates
        end
        old, new = prepare_plan missions: 2, model: model

        FlexMock.use do |mock|
            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once

            old.when_finalized { |task| mock.should_not_be_passed_on(task) }
            old.when_finalized(on_replace: :copy) { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)
            assert_equal(1, new.finalization_handlers.size)
            assert_equal(new.finalization_handlers[0].block, old.finalization_handlers[1].block)

            execute do
                plan.remove_task(old)
                plan.remove_task(new)
            end
        end
    end

    def test_finalization_handlers_are_copied_by_default_on_abstract_tasks
        model = Roby::Task.new_submodel do
            terminates
        end
        old = prepare_plan add: 1, model: Roby::Task
        new = prepare_plan add: 1, model: model

        FlexMock.use do |mock|
            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once

            old.when_finalized(on_replace: :drop) { |task| mock.should_not_be_passed_on(task) }
            old.when_finalized { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)
            assert_equal(1, new.finalization_handlers.size)
            assert_equal(new.finalization_handlers[0].block, old.finalization_handlers[1].block)

            execute do
                plan.remove_task(old)
                plan.remove_task(new)
            end
        end
    end

    def test_plain_all_and_root_sources
        source, target = prepare_plan add: 2, model: Roby::Tasks::Simple
        source.stop_event.forward_to target.aborted_event

        execute { source.start! }
        execute { target.start! }
        execute { source.stop! }
        event = target.stop_event.last

        assert_equal [target.failed_event].map(&:last).to_set, event.sources.to_set
        assert_equal [source.failed_event, source.stop_event, target.aborted_event, target.failed_event].map(&:last).to_set, event.all_sources.to_set
        assert_equal [source.failed_event].map(&:last).to_set, event.root_sources.to_set

        assert_equal [target.failed_event].map(&:last).to_set, event.task_sources.to_set
        assert_equal [target.aborted_event, target.failed_event].map(&:last).to_set, event.all_task_sources.to_set
        assert_equal [target.aborted_event].map(&:last).to_set, event.root_task_sources.to_set
    end

    def test_task_as_plan
        task_t = Roby::Task.new_submodel
        task, planner_task = task_t.new, task_t.new
        task.planned_by planner_task
        flexmock(Roby.app).should_receive(:prepare_action)
                          .with(task_t, any).and_return([task, planner_task])

        plan.add(as_plan = task_t.as_plan)
        assert_same task, as_plan
    end

    def test_emit_failed_on_start_event_causes_the_task_to_be_marked_as_failed_to_start
        plan.add(task = Roby::Tasks::Simple.new)
        execute { task.start_event.emit_failed("test") }
        assert task.failed_to_start?
        assert_kind_of Roby::EmissionFailed, task.failure_reason
    end

    def test_raising_an_EmissionFailed_error_in_calling_causes_the_task_to_be_marked_as_failed_to_start
        plan.add(task = Tasks::Simple.new)
        e = EmissionFailed.new(nil, task.start_event)
        flexmock(task.start_event).should_receive(:calling).and_raise(e)
        execute { task.start! }
        assert task.failed_to_start?
    end

    def test_raising_a_CommandFailed_error_in_calling_causes_the_task_to_be_marked_as_failed_to_start
        plan.add(task = Tasks::Simple.new)
        e = CommandFailed.new(nil, task.start_event)
        flexmock(task.start_event).should_receive(:calling).and_raise(e)
        execute { task.start! }
        assert task.failed_to_start?
    end

    def test_model_terminal_event_forces_terminal
        task_model = Roby::Task.new_submodel do
            event :terminal, terminal: true
        end
        plan.add(task = task_model.new)
        assert(task.event(:terminal).terminal?)
    end

    def test_unreachable_handlers_are_called_after_on_stop
        task_m = Roby::Task.new_submodel do
            terminates
            event :intermediate
        end
        recorder = flexmock
        plan.add(task = task_m.new)
        task.stop_event.on do
            recorder.on_stop
        end
        task.intermediate_event.when_unreachable do
            recorder.when_unreachable
        end
        recorder.should_receive(:on_stop).once.ordered
        recorder.should_receive(:when_unreachable).once.ordered
        execute do
            task.start!
            task.stop!
        end
    end

    def test_event_to_execution_exception_matcher_matches_the_event_specifically
        plan.add(task = Roby::Task.new)
        matcher = task.stop_event.to_execution_exception_matcher
        assert(matcher === LocalizedError.new(task.stop_event).to_execution_exception)
        assert(!(matcher === LocalizedError.new(Roby::Task.new.stop_event).to_execution_exception))
    end

    def test_has_argument_p_returns_true_if_the_argument_is_set
        task_m = Roby::Task.new_submodel { argument :arg }
        plan.add(task = task_m.new(arg: 10))
        assert task.has_argument?(:arg)
    end

    def test_has_argument_p_returns_true_if_the_argument_is_set_with_nil
        task_m = Roby::Task.new_submodel { argument :arg }
        plan.add(task = task_m.new(arg: nil))
        assert task.has_argument?(:arg)
    end

    def test_has_argument_p_returns_false_if_the_argument_is_not_set
        task_m = Roby::Task.new_submodel { argument :arg }
        plan.add(task = task_m.new)
        assert !task.has_argument?(:arg)
    end

    def test_has_argument_p_returns_false_if_the_argument_is_a_delayed_argument
        task_m = Roby::Task.new_submodel { argument :arg }
        delayed_arg = flexmock(evaluate_delayed_argument: nil)
        plan.add(task = task_m.new(arg: delayed_arg))
        assert !task.has_argument?(:arg)
    end

    def test_it_does_not_call_the_setters_for_delayed_arguments
        task_m = Roby::Task.new_submodel { argument :arg }
        flexmock(task_m).new_instances.should_receive(:arg=).never
        task_m.new(arg: flexmock(evaluate_delayed_argument: 10))
    end

    def test_it_calls_the_setters_when_delayed_arguments_are_resolved
        task_m = Roby::Task.new_submodel { argument :arg }
        flexmock(task_m).new_instances.should_receive(:arg=).once.with(10)
        arg = Class.new do
            def evaluate_delayed_argument(task)
                10
            end
        end.new
        plan.add(task = task_m.new(arg: arg))
        task.freeze_delayed_arguments
    end
end
