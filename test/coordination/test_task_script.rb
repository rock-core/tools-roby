require 'roby/test/self'
require 'roby/tasks/simple'
require 'roby/schedulers/temporal'

class TC_Coordination_TaskScript < Minitest::Test
    def setup
        super
        engine.scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
    end

    def test_execute
        task = prepare_plan :missions => 1, :model => Roby::Tasks::Simple
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
        task = prepare_plan :missions => 1, :model => Roby::Tasks::Simple
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
        task = prepare_plan :missions => 1, :model => Roby::Tasks::Simple
        counter = 0
        task.script do
            poll do
                counter += 1
                if counter == 4
                    transition!
                end
            end
            emit :success
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
        task = prepare_plan :missions => 1, :model => Roby::Tasks::Simple
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
        task = prepare_plan :missions => 1, :model => Roby::Tasks::Simple
        recorder = flexmock
        recorder.should_receive(:called).with(task)
        task.script do
            poll do
                recorder.called(self)
            end
            emit :success
        end
        task.start!
        task.emit :poll_transition
    end

    def test_wait_for_event
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
        end
        task = prepare_plan :missions => 1, :model => model
        counter = 0
        task.script do
            wait :intermediate
            execute { counter += 1 }
        end
        task.start!

        3.times { process_events }
        assert_equal 0, counter
        task.emit :intermediate
        3.times { process_events }
        assert_equal 1, counter
    end

    def test_child_of_real_task_is_modelled_using_the_actual_tasks_model
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
        end
        parent, child = prepare_plan :missions => 1, :add => 1, :model => model
        parent.depends_on(child, :role => 'subtask')

        script_child = parent.script.subtask_child
        assert_equal model, script_child.model.model
    end

    def test_wait_for_child_event
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
        end
        parent, child = prepare_plan :missions => 1, :add => 1, :model => model
        parent.depends_on(child, :role => 'subtask')

        counter = 0
        parent.script do
            wait intermediate_event
            execute { counter += 1 }
            wait subtask_child.intermediate_event
            execute { counter += 1 }
        end
        parent.start!

        3.times { process_events }
        assert_equal 0, counter
        parent.emit :intermediate
        3.times { process_events }
        assert_equal 1, counter
        child.emit :intermediate
        3.times { process_events }
        assert_equal 2, counter
    end

    def test_wait_for_child_of_child_event_with_child_being_deployed_later
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
        end
        parent, (child, planning_task) = prepare_plan :missions => 1, :add => 2, :model => model
        parent.depends_on(child, :role => 'subtask')

        recorder = flexmock
        recorder.should_receive(:first_execute).once.ordered
        recorder.should_receive(:second_execute).once.ordered
        parent.script do
            wait intermediate_event
            execute do
                recorder.first_execute
                child.depends_on(model.new, :role => 'subsubtask')
            end
            wait subtask_child.subsubtask_child.intermediate_event
            execute do
                recorder.second_execute
            end
        end
        parent.start!

        parent.emit :intermediate
        process_events
        child.subsubtask_child.emit :intermediate
    end

    def test_sleep
        task = prepare_plan :missions => 1, :model => Roby::Tasks::Simple

        FlexMock.use(Time) do |mock|
            time = Time.now
            mock.should_receive(:now).and_return { time }
            task.script do
                sleep 5
                emit :success
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

    def test_wait_after
        task = prepare_plan :missions => 1, :model => Roby::Tasks::Simple
        time = Time.now
        task.start!
        task.script do
            wait start_event, :after => time
            emit :success
        end
        process_events
        assert task.success?
    end

    def test_wait_barrier
        model = Roby::Tasks::Simple.new_submodel do
            3.times do |i|
                event "event#{i + 1}"
                event "found_event#{i + 1}"
            end
        end
        task = prepare_plan :missions => 1, :model => model

        task.script do
            wait_any event1_event
            emit :found_event1
            wait event2_event
            emit :found_event2
            wait event3_event
            emit :found_event3
        end

        task.start!
        task.emit :event1
        task.emit :event2
        task.emit :event3
        process_events
        assert task.found_event1?
        assert task.found_event2?
        assert task.found_event3?
    end

    def test_timeout_pass
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
            event :timeout
        end
        task = prepare_plan :missions => 1, :model => model

        FlexMock.use(Time) do |mock|
            time = Time.now
            mock.should_receive(:now).and_return { time }

            plan.add(task)
            task.script do
                timeout 5, :emit => :timeout do
                    wait intermediate_event
                end
                emit :success
            end
            task.start!

            process_events
            assert task.running?
            task.emit :intermediate
            process_events
            assert task.success?
        end
    end

    def test_timeout_fail
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
            event :timeout
        end
        task = prepare_plan :missions => 1, :model => model

        mock = flexmock(Time)
        time = Time.now
        mock.should_receive(:now).and_return { time }

        task.script do
            timeout 5, :emit => :timeout do
                wait intermediate_event
            end
            emit :success
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
        task = prepare_plan :permanent => 1, :model => model

        task.script do
            wait start_script1_event
            emit :done_script1
        end
        task.script do
            wait done_script2_event
            emit :done_script2
        end

        process_events
        process_events
        task.emit :start_script1
        process_events
        assert task.done_script1?
        assert !task.done_script2?
        plan.unmark_permanent(task)
        inhibit_fatal_messages do
            assert_raises(Roby::Coordination::Script::DeadInstruction) do
                task.done_script2_event.unreachable!
            end
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
        task = prepare_plan :permanent => 1, :model => model
        task.script do
            wait start_child_event
            child_task = start(child_model, :role => "subtask")
            execute do
                mock.child_started(child_task.resolve.running?)
            end
        end
        task.start!

        child = task.subtask_child
        assert_kind_of(child_model, child)
        assert(!child.running?)

        task.emit :start_child
        process_events
        assert task.subtask_child.running?
    end

    def test_execute_always_goes_on_regardless_of_the_output_of_the_block
        task = prepare_plan :permanent => 1, :model => Tasks::Simple
        task.script do
            execute { true }
            emit :success
        end
        task.start!
        assert task.success?

        task = prepare_plan :permanent => 1, :model => Tasks::Simple
        task.script do
            execute { false }
            emit :success
        end
        task.start!
        assert task.success?
    end

    def test_execute_block_is_evaluated_in_the_context_of_the_root_task
        context = nil
        task = prepare_plan :permanent => 1, :model => Tasks::Simple
        task.script do
            execute { context = self }
        end
        task.start!
        assert_equal task, context
    end

    def test_model_level_script
        engine.scheduler.enabled = false
        mock = flexmock
        model = Roby::Tasks::Simple.new_submodel do
            event :do_it
            event :done
            script do
                execute { mock.before_called(self) }
                wait :do_it
                emit :done
                execute { mock.after_called(self) }
            end
        end

        task1, task2 = prepare_plan :permanent => 2, :model => model
        mock.should_receive(:before_called).with(task1).once.ordered
        mock.should_receive(:before_called).with(task2).once.ordered
        mock.should_receive(:after_called).with(task1).once.ordered
        mock.should_receive(:event_emitted).with(task1).once.ordered
        mock.should_receive(:after_called).with(task2).once.ordered
        mock.should_receive(:event_emitted).with(task2).once.ordered

        task1.on(:done) { |ev| mock.event_emitted(ev.task) }
        task2.on(:done) { |ev| mock.event_emitted(ev.task) }

        task1.start!
        task2.start!
        task1.emit :do_it
        task2.emit :do_it
    end

    def test_script_is_prepared_with_the_new_task_after_a_replacement
        model = Roby::Task.new_submodel { terminates }
        old, new = prepare_plan :add => 2, :model => model
        old.abstract = true
        script = old.script do
            emit success_event
        end
        plan.replace_task(old, new)
        new.start!
        assert new.success?
    end

    def test_transaction_commits_new_script_on_pending_task
        task = prepare_plan :permanent => 1, :model => Roby::Tasks::Simple
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
        task = prepare_plan :permanent => 1, :model => Roby::Tasks::Simple
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

