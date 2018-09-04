require 'roby/test/self'
require 'roby/tasks/simple'
require 'roby/schedulers/temporal'

module Roby
    module Coordination
        describe TaskScript do
            describe "#wait" do
                attr_reader :root, :task_m, :event_source_task
                before do
                    @task_m = Tasks::Simple.new_submodel do
                        event :test
                    end
                    plan.add(@root = task_m.new)
                end

                # Common behaviour description for all the possible waiting
                # options
                def self.common_behaviour(context)
                    context.it "does not pass if the event was already emitted" do
                        event_source_task = self.event_source_task
                        root.script do
                            wait event_source_task.start_event
                            emit success_event
                        end
                        expect_execution { root.start! }.
                            to { not_emit root.stop_event }
                    end
                    context.it "passes after a new emission" do
                        event_source_task = self.event_source_task
                        root.script do
                            wait event_source_task.test_event
                            emit success_event
                        end
                        execute { root.start! }
                        execute { event_source_task.start! } if !event_source_task.running?
                        expect_execution { event_source_task.test_event.emit }.
                            to { emit root.stop_event }
                    end
                    context.it "does not pass if the event is emitted before an explicit deadline" do
                        event_source_task = self.event_source_task
                        Timecop.freeze(t = Time.now)
                        root.script do
                            wait event_source_task.test_event, after: t + 10
                            emit success_event
                        end
                        execute { root.start! }
                        execute { event_source_task.start! } if !event_source_task.running?
                        expect_execution { event_source_task.test_event.emit }.
                            to { not_emit root.stop_event }
                    end
                    context.it "passes if the event is emitted after an explicit deadline" do
                        event_source_task = self.event_source_task
                        Timecop.freeze(t = Time.now)
                        root.script do
                            wait event_source_task.test_event, after: t + 10
                            emit success_event
                        end
                        execute { root.start! }
                        execute { event_source_task.start! } if !event_source_task.running?
                        Timecop.travel(t + 11)
                        expect_execution { event_source_task.test_event.emit }.
                            to { emit root.stop_event }
                    end
                    context.it "fails if the event becomes unreachable" do
                        event_source_task = self.event_source_task
                        root.script do
                            wait event_source_task.test_event
                            emit success_event
                        end
                        expect_execution do
                            root.start!
                            event_source_task.start! if !event_source_task.running?
                            event_source_task.test_event.unreachable!
                        end.to { have_error_matching Models::Script::DeadInstruction.match.with_origin(root) }
                    end
                end

                def self.event_source_as_child_behaviour(context)
                    common_behaviour(context)
                    context.it "fails right away if the event is unreachable" do
                        event_source_task = self.event_source_task
                        root.script do
                            wait event_source_task.test_event
                            emit success_event
                        end
                        expect_execution do
                            event_source_task.start!
                            event_source_task.stop!
                            root.start!
                        end.to { have_error_matching Models::Script::DeadInstruction.match.with_origin(root) }
                    end
                end

                describe "waiting for a root event" do
                    before do
                        @event_source_task = root
                    end
                    common_behaviour(self)
                end

                describe "waiting for another task's event" do
                    before do
                        plan.add(@event_source_task = task_m.new)
                    end

                    event_source_as_child_behaviour(self)

                    it "adds the child as a dependency" do
                        event_source_task = self.event_source_task
                        root.script do
                            wait event_source_task.start_event
                        end
                        execute { root.start! }
                        assert root.depends_on?(event_source_task)
                    end
                    it "removes the dependency after the wait" do
                        event_source_task = self.event_source_task
                        recorder = flexmock
                        root.script do
                            wait event_source_task.start_event
                            execute { recorder.is_child?(depends_on?(event_source_task)) }
                        end
                        recorder.should_receive(:is_child?).with(false).once
                        execute do
                            root.start!
                            event_source_task.start!
                        end
                    end
                end
                describe "waiting for a child task's event" do
                    before do
                        root.depends_on(@event_source_task = task_m.new, role: 'test', success: nil)
                    end

                    event_source_as_child_behaviour(self)

                    it "does not remove the child when the event is emitted" do
                        recorder = flexmock
                        event_source_task = self.event_source_task
                        root.script do
                            wait test_child.test_event
                            execute { recorder.is_child?(depends_on?(event_source_task)) }
                        end
                        recorder.should_receive(:is_child?).with(true).once
                        execute do
                            root.start!
                            event_source_task.start!
                        end
                        execute { event_source_task.test_event.emit }
                    end
                    it "does not remove the child when the event is emitted even if it has no explicit role" do
                        recorder = flexmock
                        event_source_task = self.event_source_task
                        root.remove_child(event_source_task)
                        root.depends_on(event_source_task)
                        root.script do
                            wait event_source_task.start_event
                            execute { recorder.is_child?(depends_on?(event_source_task)) }
                        end
                        recorder.should_receive(:is_child?).with(true).once
                        execute { root.start!; event_source_task.start! }
                    end
                end

                it "can resolve an event of a child-of-a-child even if the grandchild does not exist at model time" do
                    root.depends_on(child = task_m.new, role: 'test')

                    recorder = flexmock
                    recorder.should_receive(:first_execute).once.ordered
                    recorder.should_receive(:second_execute).once.ordered
                    task_m = self.task_m
                    root.script do
                        wait test_event
                        execute do
                            recorder.first_execute
                            child.depends_on(task_m.new, role: 'subtask')
                        end
                        wait test_child.subtask_child.test_event
                        execute do
                            recorder.second_execute
                        end
                    end
                    execute { root.start! }
                    execute { root.test_event.emit }
                    execute { child.subtask_child.start! }
                    execute { child.subtask_child.test_event.emit }
                end
            end

            describe "#timeout" do
                attr_reader :task
                before do
                    task_m = Roby::Tasks::Simple.new_submodel do
                        event :intermediate
                        event :timeout
                    end
                    plan.add(@task = task_m.new)
                end

                describe "with an event" do
                    before do
                        task.script do
                            timeout 1, emit: timeout_event do
                                wait intermediate_event
                            end
                            emit success_event
                        end
                    end

                    it "passes if the sub-script finished before the timeout" do
                        Timecop.freeze(Time.now)
                        expect_execution { task.start! }.to { not_emit task.stop_event }
                        expect_execution { task.intermediate_event.emit }.
                            to { emit task.stop_event }
                    end

                    it "emits the timeout event and moves on if the sub-script has "\
                        "not finished in time" do
                        Timecop.freeze(base_time = Time.now)
                        execute { task.start! }

                        expect_execution { Timecop.freeze(base_time + 1.1) }.
                            to { emit task.timeout_event }
                    end
                end

                describe "without an event" do
                    before do
                        task.script do
                            timeout 1 do
                                wait intermediate_event
                            end
                            emit success_event
                        end
                    end

                    it "passes if the sub-script finished before the timeout" do
                        Timecop.freeze(Time.now)
                        expect_execution { task.start! }.to { not_emit task.stop_event }
                        expect_execution { task.intermediate_event.emit }.
                            to { emit task.stop_event }
                    end

                    it "raises TimedOut if the sub-script has not finished in time" do
                        Timecop.freeze(Time.now)
                        execute { task.start! }

                        expect_execution.poll { Timecop.freeze(Time.now + 0.3) }.
                            to { have_error_matching Script::TimedOut }
                    end
                end
            end
        end
    end
end


class TC_Coordination_TaskScript < Minitest::Test
    def setup
        super
        execution_engine.scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
    end

    def test_execute
        task = prepare_plan missions: 1, model: Roby::Tasks::Simple
        counter = 0
        task.script do
            execute do
                counter += 1
            end
        end
        expect_execution { task.start! }.
            to { achieve { counter == 1 } }
        execute_one_cycle
        assert_equal 1, counter
    end

    def test_execute_and_emit
        task = prepare_plan missions: 1, model: Roby::Tasks::Simple
        counter = 0
        task.script do
            execute do
                counter += 1
            end
            emit success_event
        end

        expect_execution { task.start! }.
            to { emit task.success_event }
        assert_equal 1, counter
    end

    def test_poll
        task = prepare_plan missions: 1, model: Roby::Tasks::Simple
        counter = 0
        task.script do
            poll do
                counter += 1
                if counter == 4
                    transition!
                end
            end
            emit success_event
        end

        expect_execution { task.start! }.
            to { emit task.success_event }
        assert_equal 4, counter
    end

    def test_cancelling_a_poll_operation_deregisters_the_poll_handler
        task = prepare_plan missions: 1, model: Roby::Tasks::Simple
        recorder = flexmock
        script = task.model.create_script(task) do
            poll do
                recorder.called
            end
        end
        execute { task.start! }
        script.prepare

        recorder.should_receive(:called).never
        script.step
        script.current_instruction.cancel
        script.step
    end

    def test_quitting_a_poll_operation_deregisters_the_poll_handler
    end

    def test_poll_evaluates_the_block_in_the_context_of_the_root_task
        task = prepare_plan missions: 1, model: Roby::Tasks::Simple
        recorder = flexmock
        recorder.should_receive(:called).with(task)
        task.script do
            poll do
                recorder.called(self)
            end
            emit success_event
        end
        execute { task.start! }
        execute { task.poll_transition_event.emit }
    end

    def test_child_of_real_task_is_modelled_using_the_actual_tasks_model
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
        end
        parent, child = prepare_plan missions: 1, add: 1, model: model
        parent.depends_on(child, role: 'subtask')

        script_child = parent.script.subtask_child
        assert_equal model, script_child.model.model
    end

    def test_sleep
        plan.add(task = Roby::Tasks::Simple.new)

        Timecop.freeze(base_time = Time.now)
        task.script do
            sleep 1
            emit success_event
        end

        expect_execution { task.start! }.to { not_emit task.stop_event }
        Timecop.freeze(base_time + 0.1)
        expect_execution.to { not_emit task.stop_event }
        Timecop.freeze(base_time + 1.1)
        expect_execution.to { emit task.stop_event }
    end

    def test_parallel_scripts
        task_m = Roby::Tasks::Simple.new_submodel do
            event :start_script1
            event :done_script1
            event :start_script2
            event :done_script2
        end
        plan.add(task = task_m.new)

        task.script do
            wait start_script1_event
            emit done_script1_event
        end
        task.script do
            wait done_script2_event
            emit done_script2_event
        end

        execute { task.start! }
        expect_execution { task.start_script1_event.emit }.
            to do
                emit task.done_script1_event
                not_emit task.done_script2_event
            end

        expect_execution { task.done_script2_event.unreachable! }.
            to do
                have_error_matching Roby::Coordination::Script::DeadInstruction.match.
                    with_origin(task)
                not_emit task.done_script2_event
            end
    end

    def test_start
        task_m = Roby::Tasks::Simple.new_submodel do
            event :start_child
        end
        child_task_m = Roby::Tasks::Simple.new_submodel

        plan.add(task = task_m.new)
        recorder = flexmock
        recorder.should_receive(:child_started).with(true).once
        task.script do
            wait start_child_event
            child_task = start(child_task_m, role: "subtask")
            execute do
                recorder.child_started(child_task.resolve.running?)
            end
        end

        execute { task.start! }

        child = task.subtask_child
        assert_kind_of child_task_m, child
        refute child.running?

        expect_execution { task.start_child_event.emit }.
            scheduler(Roby::Schedulers::Basic.new(true, plan)).
            to { have_running task.subtask_child }
    end

    def test_execute_always_goes_on_regardless_of_the_output_of_the_block
        task = prepare_plan permanent: 1, model: Tasks::Simple
        task.script do
            execute { true }
            emit success_event
        end
        expect_execution { task.start! }.
            to { emit task.success_event }

        task = prepare_plan permanent: 1, model: Tasks::Simple
        task.script do
            execute { false }
            emit success_event
        end
        expect_execution { task.start! }.
            to { emit task.success_event }
    end

    def test_execute_block_is_evaluated_in_the_context_of_the_root_task
        context = nil
        task = prepare_plan permanent: 1, model: Tasks::Simple
        task.script do
            execute { context = self }
        end
        execute { task.start! }
        assert_equal task, context
    end

    def test_model_level_script
        execution_engine.scheduler.enabled = false
        mock = flexmock
        model = Roby::Tasks::Simple.new_submodel do
            event :do_it
            event :done
            script do
                execute { mock.before_called(self) }
                wait do_it_event
                emit done_event
                execute { mock.after_called(self) }
            end
        end

        task1, task2 = prepare_plan permanent: 2, model: model
        mock.should_receive(:before_called).with(task1).once.ordered
        mock.should_receive(:before_called).with(task2).once.ordered
        mock.should_receive(:after_called).with(task1).once.ordered
        mock.should_receive(:event_emitted).with(task1).once.ordered
        mock.should_receive(:after_called).with(task2).once.ordered
        mock.should_receive(:event_emitted).with(task2).once.ordered

        task1.done_event.on { |ev| mock.event_emitted(ev.task) }
        task2.done_event.on { |ev| mock.event_emitted(ev.task) }

        execute do
            task1.start!
            task2.start!
        end
        execute { task1.do_it_event.emit }
        execute { task2.do_it_event.emit }
    end

    def test_script_is_prepared_with_the_new_task_after_a_replacement
        model = Roby::Task.new_submodel { terminates }
        old, new = prepare_plan add: 2, model: model
        old.abstract = true
        old.script do
            emit success_event
        end
        plan.replace_task(old, new)
        expect_execution { new.start! }.
            to { emit new.success_event }
    end

    def test_transaction_commits_new_script_on_pending_task
        plan.add(task = Roby::Tasks::Simple.new)
        task.executable = false

        mock = flexmock
        mock.should_receive(:executed).with(false).never.globally.ordered
        mock.should_receive(:barrier).once.globally.ordered
        mock.should_receive(:executed).with(true).once.globally.ordered
        executed = false
        plan.in_transaction do |trsc|
            proxy = trsc[task]
            proxy.script do
                execute do
                    executed = true
                    mock.executed(task.executable?)
                end
            end
            execute_one_cycle
            mock.barrier
            trsc.commit_transaction
        end
        execute_one_cycle
        task.executable = true
        expect_execution { task.start! }.
            to { achieve { executed = true } }
    end

    def test_transaction_commits_new_script_on_running_task
        plan.add(task = Roby::Tasks::Simple.new)
        execute { task.start! }

        mock = flexmock
        mock.should_receive(:executed).with(false).never.ordered
        mock.should_receive(:barrier).once.ordered
        mock.should_receive(:executed).with(true).once.ordered
        executed = false
        plan.in_transaction do |trsc|
            proxy = trsc[task]
            proxy.script do
                execute do
                    executed = true
                    mock.executed(task.executable?)
                end
            end
            execute_one_cycle
            mock.barrier
            trsc.commit_transaction
        end
        expect_execution.to { achieve { executed } }
    end
end
