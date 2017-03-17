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
                        root.start!
                        refute root.finished?
                    end
                    context.it "passes after a new emission" do
                        event_source_task = self.event_source_task
                        root.script do
                            wait event_source_task.test_event
                            emit success_event
                        end
                        root.start!
                        event_source_task.start! if !event_source_task.running?
                        event_source_task.test_event.emit
                        assert root.finished?
                    end
                    context.it "does not pass if the event is emitted before an explicit deadline" do
                        event_source_task = self.event_source_task
                        Timecop.freeze(t = Time.now)
                        root.script do
                            wait event_source_task.test_event, after: t + 10
                            emit success_event
                        end
                        root.start!
                        event_source_task.start! if !event_source_task.running?
                        event_source_task.test_event.emit
                        refute root.finished?
                    end
                    context.it "passes if the event is emitted after an explicit deadline" do
                        event_source_task = self.event_source_task
                        Timecop.freeze(t = Time.now)
                        root.script do
                            wait event_source_task.test_event, after: t + 10
                            emit success_event
                        end
                        root.start!
                        event_source_task.start! if !event_source_task.running?
                        Timecop.travel(t + 11)
                        event_source_task.test_event.emit
                        assert root.finished?
                    end
                    context.it "fails if the event becomes unreachable" do
                        event_source_task = self.event_source_task
                        root.script do
                            wait event_source_task.test_event
                            emit success_event
                        end
                        root.start!
                        event_source_task.start! if !event_source_task.running?
                        assert_fatal_exception(Models::Script::DeadInstruction, failure_point: root, tasks: [root]) do
                            event_source_task.test_event.unreachable!
                        end
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
                        event_source_task.start!; event_source_task.stop!

                        assert_fatal_exception(Models::Script::DeadInstruction, failure_point: root, tasks: [root]) do
                            root.start!
                        end
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
                        recorder = flexmock
                        root.script do
                            wait event_source_task.start_event
                        end
                        root.start!
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
                        root.start!; event_source_task.start!
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
                        root.start!
                        event_source_task.start!
                        event_source_task.test_event.emit
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
                        root.start!; event_source_task.start!
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
                    root.start!
                    root.test_event.emit
                    child.subtask_child.start!
                    child.subtask_child.test_event.emit
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
        task.start!

        process_events
        process_events
        process_events
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
        task.start!

        process_events
        process_events
        process_events
        process_events
        assert_equal 1, counter
        assert task.success?
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
        task.start!

        process_events
        process_events
        process_events
        process_events
        assert_equal 4, counter
        # Make the poll block transition
        assert !task.failed?
    end

    def test_cancelling_a_poll_operation_deregisters_the_poll_handler
        task = prepare_plan missions: 1, model: Roby::Tasks::Simple
        recorder = flexmock
        script = task.model.create_script(task) do
            poll do
                recorder.called
            end
        end
        task.start!
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
        task.start!
        task.poll_transition_event.emit
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
        task = prepare_plan missions: 1, model: Roby::Tasks::Simple

        FlexMock.use(Time) do |mock|
            time = Time.now
            mock.should_receive(:now).and_return { time }
            task.script do
                sleep 5
                emit success_event
            end

            task.start!
            process_events
            assert !task.finished?
            time = time + 3
            process_events
            assert !task.finished?
            time = time + 3
            process_events
            assert task.finished?
        end
    end

    def test_timeout_pass
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
            event :timeout
        end
        task = prepare_plan missions: 1, model: model

        FlexMock.use(Time) do |mock|
            time = Time.now
            mock.should_receive(:now).and_return { time }

            plan.add(task)
            task.script do
                timeout 5, emit: :timeout do
                    wait intermediate_event
                end
                emit success_event
            end
            task.start!

            process_events
            assert task.running?
            task.intermediate_event.emit
            process_events
            assert task.success?
        end
    end

    def test_timeout_fail
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
            event :timeout
        end
        task = prepare_plan missions: 1, model: model

        mock = flexmock(Time)
        time = Time.now
        mock.should_receive(:now).and_return { time }

        task.script do
            timeout 5, emit: :timeout do
                wait intermediate_event
            end
            emit success_event
        end
        task.start!
        process_events

        assert task.running?
        time += 6
        process_events
        assert task.timeout?
        assert task.success?
    end

    def test_parallel_scripts
        model = Roby::Tasks::Simple.new_submodel do
            event :start_script1
            event :done_script1
            event :start_script2
            event :done_script2
        end
        task = prepare_plan permanent: 1, model: model

        task.script do
            wait start_script1_event
            emit done_script1_event
        end
        task.script do
            wait done_script2_event
            emit done_script2_event
        end

        process_events
        process_events
        task.start_script1_event.emit
        process_events
        assert task.done_script1?
        assert !task.done_script2?
        plan.unmark_permanent_task(task)
        assert_fatal_exception(Roby::Coordination::Script::DeadInstruction, failure_point: task, tasks: [task]) do
            task.done_script2_event.unreachable!
        end
        assert task.done_script1?
        assert !task.done_script2?
    end

    def test_start
        mock = flexmock
        mock.should_receive(:child_started).once.with(true)

        model = Roby::Tasks::Simple.new_submodel do
            event :start_child
        end
        child_model = Roby::Tasks::Simple.new_submodel

        task = nil
        task = prepare_plan permanent: 1, model: model
        task.script do
            wait start_child_event
            child_task = start(child_model, role: "subtask")
            execute do
                mock.child_started(child_task.resolve.running?)
            end
        end
        task.start!

        child = task.subtask_child
        assert_kind_of(child_model, child)
        assert(!child.running?)

        task.start_child_event.emit
        process_events
        assert task.subtask_child.running?
    end

    def test_execute_always_goes_on_regardless_of_the_output_of_the_block
        task = prepare_plan permanent: 1, model: Tasks::Simple
        task.script do
            execute { true }
            emit success_event
        end
        task.start!
        assert task.success?

        task = prepare_plan permanent: 1, model: Tasks::Simple
        task.script do
            execute { false }
            emit success_event
        end
        task.start!
        assert task.success?
    end

    def test_execute_block_is_evaluated_in_the_context_of_the_root_task
        context = nil
        task = prepare_plan permanent: 1, model: Tasks::Simple
        task.script do
            execute { context = self }
        end
        task.start!
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

        task1.start!
        task2.start!
        task1.do_it_event.emit
        task2.do_it_event.emit
    end

    def test_script_is_prepared_with_the_new_task_after_a_replacement
        model = Roby::Task.new_submodel { terminates }
        old, new = prepare_plan add: 2, model: model
        old.abstract = true
        script = old.script do
            emit success_event
        end
        plan.replace_task(old, new)
        new.start!
        assert new.success?
    end

    def test_transaction_commits_new_script_on_pending_task
        task = prepare_plan permanent: 1, model: Roby::Tasks::Simple
        task.executable = false

        mock = flexmock
        mock.should_receive(:executed).with(false).never.ordered
        mock.should_receive(:barrier).once.ordered
        mock.should_receive(:executed).with(true).once.ordered
        plan.in_transaction do |trsc|
            proxy = trsc[task]
            proxy.script do
                execute do
                    mock.executed(task.executable?)
                end
            end
            process_events
            mock.barrier
            trsc.commit_transaction
        end
        process_events
        task.executable = true
        task.start!
        process_events
        process_events
    end

    def test_transaction_commits_new_script_on_running_task
        task = prepare_plan permanent: 1, model: Roby::Tasks::Simple
        task.start!

        mock = flexmock
        mock.should_receive(:executed).with(false).never.ordered
        mock.should_receive(:barrier).once.ordered
        mock.should_receive(:executed).with(true).once.ordered
        plan.in_transaction do |trsc|
            proxy = trsc[task]
            proxy.script do
                execute do
                    mock.executed(task.executable?)
                end
            end
            process_events
            mock.barrier
            trsc.commit_transaction
        end
        process_events
        process_events
    end
end

