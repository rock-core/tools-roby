require 'roby/test/self'
require './test/mockups/tasks'
require 'utilrb/hash/slice'

Roby::TaskStructure.relation :WeakTest, weak: true, child_name: 'weak_test'

module Roby
    describe ExecutionEngine do
        describe "event_ordering" do
            it "is not cleared if events withou precedence relations are added to the plan" do
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

        describe "management of the needs_garbage_collection flag" do
            after do
                plan.each_task do |task|
                    if task.starting?
                        task.start_event.emit
                    end
                    if task.running?
                        task.stop_event.emit
                    end
                end
            end
            it "is set if a new task is added" do
                flexmock(execution_engine).should_receive(:needs_garbage_collection!).once
                plan.add(Task.new)
            end
            it "is set if a new free event is added" do
                flexmock(execution_engine).should_receive(:needs_garbage_collection!).once
                plan.add(EventGenerator.new)
            end
            it "is set if a relation with a free event as parent is removed" do
                plan.add(t = Task.new)
                plan.add(e = EventGenerator.new)
                e.forward_to t.start_event
                flexmock(execution_engine).should_receive(:needs_garbage_collection!).once
                e.remove_forwarding t.start_event
            end
            it "is set if a relation with a free event as child is removed" do
                plan.add(t = Task.new)
                plan.add(e = EventGenerator.new)
                t.start_event.forward_to e
                flexmock(execution_engine).should_receive(:needs_garbage_collection!).once
                t.start_event.remove_forwarding e
            end
            it "is set if a relation involving a task is removed" do
                plan.add(parent = Task.new)
                plan.add(child = Task.new)
                parent.depends_on child
                flexmock(execution_engine).should_receive(:needs_garbage_collection!).once
                parent.remove_child child
            end
            it "is set if a mission task is unmarked" do
                plan.add_mission_task(task = Task.new)
                flexmock(execution_engine).should_receive(:needs_garbage_collection!).once
                plan.unmark_mission_task task
            end
            it "is set if a permanent task is unmarked" do
                plan.add_permanent_task(task = Task.new)
                flexmock(execution_engine).should_receive(:needs_garbage_collection!).once
                plan.unmark_permanent_task task
            end
            it "is set if a permanent event is unmarked" do
                plan.add_permanent_event(event = EventGenerator.new)
                flexmock(execution_engine).should_receive(:needs_garbage_collection!).once
                plan.unmark_permanent_event event
            end
            it "is set if a starting task already processed by #garbage_collect got started" do
                task_m = Tasks::Simple.new_submodel { event(:start) { |context| } }
                plan.add(task = task_m.new)
                task.start!
                execution_engine.garbage_collect
                task.start_event.emit
                assert execution_engine.needs_garbage_collection?
            end
            it "is set if a finishing task already processed by #garbage_collect got finished" do
                task_m = Tasks::Simple.new_submodel { event(:stop) { |context| } }
                plan.add(task = task_m.new)
                task.start!
                task.stop!
                execution_engine.garbage_collect
                task.stop_event.emit
                assert execution_engine.needs_garbage_collection?
            end
        end

        describe "#unmark_finished_missions_and_permanent_tasks" do
            attr_reader :task
            before do
                task_m = Task.new_submodel { event(:stop) { |context| } }
                @task = task_m.new
            end
            after do
                if task.running?
                    task.stop_event.emit
                end
            end

            def self.common(test_class)
                test_class.it "does not unmark pending tasks" do
                    execution_engine.unmark_finished_missions_and_permanent_tasks
                    assert_plan_predicate
                end
                test_class.it "does not unmark running tasks" do
                    task.start!
                    execution_engine.unmark_finished_missions_and_permanent_tasks
                    assert_plan_predicate
                end
                test_class.it "does not unmark finishing tasks" do
                    task.start!
                    task.stop!
                    execution_engine.unmark_finished_missions_and_permanent_tasks
                    assert_plan_predicate
                end
                test_class.it "unmarks tasks that are finished" do
                    task.start!
                    task.stop_event.emit
                    execution_engine.unmark_finished_missions_and_permanent_tasks
                    refute_plan_predicate
                end
                test_class.it "does not unmark finished tasks that are being repaired" do
                    task.start!
                    task.stop_event.emit
                    flexmock(task).should_receive(:being_repaired?).and_return(true)
                    execution_engine.unmark_finished_missions_and_permanent_tasks
                    assert_plan_predicate
                end
            end

            describe "handling of mission tasks" do
                attr_reader :task
                before do
                    plan.add_mission_task(task)
                end

                def assert_plan_predicate; assert plan.mission_task?(task) end
                def refute_plan_predicate; refute plan.mission_task?(task) end

                common(self)

                it "unmarks tasks that have failed to start" do
                    assert_raises(MissionFailedError) do
                        task.start_event.emit_failed
                    end
                    assert plan.mission_task?(task)
                    execution_engine.unmark_finished_missions_and_permanent_tasks
                    refute plan.mission_task?(task)
                end
            end

            describe "handling of permanent tasks" do
                before do
                    plan.add_permanent_task(task)
                end

                def assert_plan_predicate; assert plan.permanent_task?(task) end
                def refute_plan_predicate; refute plan.permanent_task?(task) end

                common(self)

                it "unmarks tasks that have failed to start" do
                    inhibit_fatal_messages do
                        task.start_event.emit_failed
                    end
                    assert plan.permanent_task?(task)
                    execution_engine.unmark_finished_missions_and_permanent_tasks
                    refute plan.permanent_task?(task)
                end
            end
        end

        describe "#gc_find_all_candidates" do
            it "returns empty if none of the tasks are eligible" do
                plan.add_mission_task(task = Tasks::Simple.new)
                assert_equal [[], []], execution_engine.gc_find_all_candidates
            end

            describe "removal tasks" do
                attr_reader :task
                before do
                    plan.add(@task = Tasks::Simple.new)
                end
                after do
                    plan.unmark_mission_task(task)
                    plan.unmark_permanent_task(task)
                    task.stop! if task.running?
                end

                it "returns a task that is root in all the task relations" do
                    assert_equal [[task], []], execution_engine.gc_find_all_candidates
                end
                it "does not return a task that has keep_in_plan?" do
                    flexmock(task).should_receive(:keep_in_plan?).and_return(true)
                    assert_equal [[], []], execution_engine.gc_find_all_candidates
                end
                it "considers directly useful tasks if they are in the force_gc set" do
                    plan.add_permanent_task(task)
                    execution_engine.force_gc_on(task)
                    assert_equal [[task], []], execution_engine.gc_find_all_candidates
                end

                it "does not return a finished task that is not root" do
                    plan.add_mission_task(root = task)
                    root.depends_on(parent = Tasks::Simple.new, remove_when_done: false)
                    parent.depends_on(child = Tasks::Simple.new)
                    parent.start!
                    parent.success_event.emit
                    assert_equal [[], []], execution_engine.gc_find_all_candidates
                end
            end

            describe "kill tasks" do
                attr_reader :task
                before do
                    plan.add(@task = Tasks::Simple.new)
                    task.start!
                end
                after do
                    plan.unmark_mission_task(task)
                    plan.unmark_permanent_task(task)
                    task.stop! if task.running?
                end

                it "returns a task that is root in all the task relations" do
                    assert_equal [[], [task]], execution_engine.gc_find_all_candidates
                end
                it "considers directly useful tasks if they are in the force_gc set" do
                    plan.add_permanent_task(task)
                    execution_engine.force_gc_on(task)
                    assert_equal [[], [task]], execution_engine.gc_find_all_candidates
                end
                describe "handling of finished tasks" do
                    attr_reader :root, :parent, :child
                    before do
                        plan.add_mission_task(@root = task)
                        root.depends_on(@parent = Tasks::Simple.new, remove_when_done: false)
                        parent.depends_on(@child = Tasks::Simple.new)
                        parent.start!
                        parent.success_event.emit
                        child.start!
                    end

                    it "returns a non-root running task that only has finished parents" do
                        assert_equal [[], [child]], execution_engine.gc_find_all_candidates
                    end
                    it "does not return a non-root task that has finished parents for which #keep_subplan? returns true" do
                        flexmock(parent).should_receive(:keep_subplan?).and_return(true)
                        assert_equal [[], []], execution_engine.gc_find_all_candidates
                    end
                    it "does not return a non-root task that has finished parents for which directly_useful_task? returns true" do
                        flexmock(plan).should_receive(:directly_useful_task?).with(parent).and_return(true)
                        flexmock(plan).should_receive(:directly_useful_task?).pass_thru
                        assert_equal [[], []], execution_engine.gc_find_all_candidates
                    end
                end
            end
        end

        describe "#gc_remove_weak_relations" do
            attr_reader :weak_graph
            before do
                @weak_graph = plan.task_relation_graph_for(TaskStructure::WeakTest)
            end

            it "removes the passed tasks from all weak relations and keeps the others" do
                plan.add(parent = Task.new)
                plan.add(child = Task.new)
                parent.add_weak_test(child)
                child.add_weak_test(grandchild = Task.new)
                execution_engine.gc_remove_weak_relations([parent])

                refute weak_graph.has_vertex?(parent)
                assert weak_graph.has_edge?(child, grandchild)
            end

            it "returns true if some vertices have been removed" do
                plan.add(task = Task.new)
                weak_graph.add_vertex(task)
                assert execution_engine.gc_remove_weak_relations([task])
            end

            it "returns false if nothing needed to be done" do
                plan.add(task = Task.new)
                weak_graph.add_vertex(task)
                refute execution_engine.gc_remove_weak_relations([])
            end

            it "returns false if no vertices were removed" do
                plan.add(task = Task.new)
                refute execution_engine.gc_remove_weak_relations([task])
            end
        end

        describe "#gc_find_all_kill_candidates_with_possible_cycles" do
            it "does nothing if removing the weak relations changed the graphs" do
                plan.add(task = Task.new)
                flexmock(execution_engine).should_receive(:gc_remove_weak_relations).
                    and_return(true)
                assert_equal [], execution_engine.gc_find_all_kill_candidates_with_possible_cycles
            end

            it "garbage collects using the dependency graph if weak graph removal did nothing" do
                plan.add(parent = Tasks::Simple.new)
                parent.depends_on(child = Tasks::Simple.new)
                parent.start!

                flexmock(execution_engine).should_receive(:gc_remove_weak_relations).
                    and_return(false)
                flexmock(execution_engine).should_receive(:gc_process_running_task).with(parent).
                    and_return(true)
                assert_equal [parent], execution_engine.
                    gc_find_all_kill_candidates_with_possible_cycles
            end
        end

        describe "#gc_process_removal" do
            attr_reader :task
            before do
                plan.add(@task = Tasks::Simple.new)
            end
            it "does not remove a task that has parents" do
                refute execution_engine.gc_process_removal(task)
                assert !plan.has_task?(task)
            end
            it "removes a pending task and returns false" do
                refute execution_engine.gc_process_removal(task)
                assert !plan.has_task?(task)
            end
            it "removes a task that failed to start and returns false" do
                task.start_event.emit_failed
                refute execution_engine.gc_process_removal(task)
                assert !plan.has_task?(task)
            end
            it "removes a finished task and returns false" do
                task.start!
                task.stop!
                refute execution_engine.gc_process_removal(task)
                refute plan.has_task?(task)
            end
        end

        describe "#gc_process_kill" do
            attr_reader :task
            before do
                plan.add(@task = Tasks::Simple.new)
            end
            after do
                if task.starting?
                    task.start_event.emit
                    task.stop_event.emit
                elsif task.finishing?
                    task.stop_event.emit
                end
            end
            it "waits for a task that is starting and returns false" do
                task_m = Task.new_submodel { event(:start) { |context| } }
                plan.add(@task = task_m.new)
                task.start!
                refute execution_engine.gc_process_kill(task)
                assert plan.has_task?(task)
            end
            it "waits for a task that is finishing and returns false" do
                task_m = Task.new_submodel { event(:stop) { |context| } }
                plan.add(@task = task_m.new)
                task.start!
                task.stop!
                refute execution_engine.gc_process_kill(task)
                assert plan.has_task?(task)
            end
            it "does nothing and returns true for a task that is running and interruptible" do
                task.start!
                assert execution_engine.gc_process_kill(task)
                assert plan.has_task?(task)
            end
            it "quarantines and returns false for a task that is running, interruptible but for which stop! is not defined" do
                task.start!
                flexmock(plan).should_receive(:quarantine).with(task).once
                flexmock(task).should_receive(:respond_to?).with(:stop!).and_return(false)

                refute execution_engine.gc_process_kill(task)
                assert plan.has_task?(task)
            end
            it "quarantines and returns false for a task that is running but for which the stop event is not controlable" do
                task_m = Task.new_submodel
                plan.add(@task = task_m.new)
                task.start!
                flexmock(plan).should_receive(:quarantine).with(task).once

                refute execution_engine.gc_process_kill(task)
                assert plan.has_task?(task)
            end
        end

        describe "#garbage_collect" do
            after do
                plan.tasks.each do |t|
                    if t.starting?
                        t.start_event.emit
                    end
                    if t.running?
                        t.stop_event.emit
                    end
                end
            end
            it "recursively removes pending tasks" do
                plan.add(parent = Task.new)
                parent.depends_on(child = Task.new)
                child.depends_on(grandchild = Task.new)
                execution_engine.garbage_collect
                assert !plan.has_task?(parent)
                assert !plan.has_task?(child)
                assert !plan.has_task?(grandchild)
            end

            it "stops iterating when it has to stop a task, and calls the stop event on it" do
                plan.add(parent = Tasks::Simple.new)
                parent.depends_on(child = Tasks::Simple.new)
                child.depends_on(grandchild = Task.new)

                child.start!
                execution_engine.garbage_collect

                refute plan.has_task?(parent)
                assert plan.has_task?(child)
                assert plan.has_task?(grandchild)
                assert child.finished?
            end

            it "stops iterating when it has to wait on a finishing task" do
                task_m = Tasks::Simple.new_submodel { event(:stop) { |context| } }
                plan.add(parent = Tasks::Simple.new)
                parent.depends_on(child = task_m.new)
                child.depends_on(grandchild = Task.new)

                child.start!
                child.stop!
                execution_engine.garbage_collect

                refute plan.has_task?(parent)
                assert plan.has_task?(child)
                assert plan.has_task?(grandchild)
            end

            it "collects on a starting task once it is started" do
                task_m = Tasks::Simple.new_submodel { event(:stop) { |context| } }
                plan.add(task = task_m.new)
                task.start!
                task.stop!
                execution_engine.garbage_collect
                assert plan.has_task?(task)
                task.stop_event.emit
                execution_engine.garbage_collect
                refute plan.has_task?(task)
            end

            it "stops iterating when it has to wait on a starting task" do
                task_m = Tasks::Simple.new_submodel { event(:start) { |context| } }
                plan.add(parent = Tasks::Simple.new)
                parent.depends_on(child = task_m.new)
                child.depends_on(grandchild = Task.new)

                child.start!
                execution_engine.garbage_collect

                refute plan.has_task?(parent)
                assert plan.has_task?(child)
                assert plan.has_task?(grandchild)
            end

            it "collects on a starting task once it is started" do
                task_m = Tasks::Simple.new_submodel { event(:start) { |context| } }
                plan.add(task = task_m.new)
                task.start!
                execution_engine.garbage_collect
                assert plan.has_task?(task)
                task.start_event.emit
                assert execution_engine.garbage_collect
                assert task.finished?
            end

            it "removes unneeded events" do
                plan.add(ev = EventGenerator.new)
                flexmock(plan).should_receive(:unneeded_events).and_return([ev])
                execution_engine.garbage_collect
                assert !plan.has_free_event?(ev)
            end

            it "leaves useful free events alone" do
                plan.add(ev = EventGenerator.new)
                flexmock(plan).should_receive(:unneeded_events).and_return([])
                execution_engine.garbage_collect
                assert plan.has_free_event?(ev)
            end

            it "garbage-collects a useful task that is added to the force-gc set" do
                plan.add_permanent_task(task = Tasks::Simple.new)
                task.start!
                execution_engine.force_gc_on(task)
                execution_engine.garbage_collect
                assert task.finished?
            end

            it "stops tasks that have finished parents but do not remove them" do
                plan.add_permanent_task(parent = Tasks::Simple.new)
                parent.depends_on(child = Tasks::Simple.new, remove_when_done: false)
                child.depends_on(grandchild = Tasks::Simple.new, remove_when_done: false)

                parent.start!
                child.start!
                grandchild.start!
                child.success_event.emit
                assert_event_emission(grandchild.stop_event)

                assert parent.running?
                assert plan.has_task?(parent)
                assert plan.has_task?(child)
                assert plan.has_task?(grandchild)
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
            { e1 => [1, nil, [nil, [1], nil, nil, [4], nil]],
              e2 => [3, [nil, [2], nil, nil, [3], nil], nil],
              e3 => [5, [nil, [6], nil], [nil, [5], nil]] }, set)
    end

    class PropagationHandlerTest
        attr_reader :event
        attr_reader :plan

        def initialize(plan, mockup)
            @mockup = mockup
            @plan = plan
            reset_event
        end

        def reset_event
            plan.add_permanent_event(@event = Roby::EventGenerator.new(true))
        end

        def handler(plan)
            if @event.history.size != 2
                @event.call
            end
            @mockup.called(plan)
        end
    end

    def test_add_propagation_handlers_for_external_events
        FlexMock.use do |mock|
            handler = PropagationHandlerTest.new(plan, mock)
            id = execution_engine.add_propagation_handler(type: :external_events) { |plan| handler.handler(plan) }

            mock.should_receive(:called).with(plan).twice

            process_events
            assert_equal(1, handler.event.history.size)

            handler.reset_event
            process_events
            assert_equal(1, handler.event.history.size)

            execution_engine.remove_propagation_handler id
            handler.reset_event
            process_events
            assert_equal(0, handler.event.history.size)
        end
    end

    def test_add_propagation_handlers_for_propagation
        FlexMock.use do |mock|
            handler = PropagationHandlerTest.new(plan, mock)
            id = execution_engine.add_propagation_handler(type: :propagation) { |plan| handler.handler(plan) }

            # In the handler, we call the event two times
            #
            # The propagation handler should be called one time more (until
            # it does not emit any event), So it will be called 6 times over the
            # whole test
            mock.should_receive(:called).with(plan).times(6)

            process_events
            assert_equal(2, handler.event.history.size)

            handler.reset_event
            process_events
            assert_equal(2, handler.event.history.size)

            execution_engine.remove_propagation_handler id
            handler.reset_event
            process_events
            assert_equal(0, handler.event.history.size)
        end
    end

    def test_add_propagation_handlers_for_propagation_late
        FlexMock.use do |mock|
            plan.add_permanent_event(event = Roby::EventGenerator.new(true))
            plan.add_permanent_event(late_event = Roby::EventGenerator.new(true))

            index = -1
            event.on { |_| mock.event_emitted(index += 1) }
            late_event.on { |_| mock.late_event_emitted(index += 1) }


            id = execution_engine.add_propagation_handler(type: :propagation) do |plan|
                mock.handler_called(index += 1)
                if !event.emitted?
                    event.emit
                end
            end
            late_id = execution_engine.add_propagation_handler(type: :propagation, late: true) do |plan|
                mock.late_handler_called(index += 1)
                if !late_event.emitted?
                    late_event.emit
                end
            end

            mock.should_receive(:handler_called).with(0).once.ordered
            mock.should_receive(:event_emitted).with(1).once.ordered
            mock.should_receive(:handler_called).with(2).once.ordered
            mock.should_receive(:late_handler_called).with(3).once.ordered
            mock.should_receive(:late_event_emitted).with(4).once.ordered
            mock.should_receive(:handler_called).with(5).once.ordered
            mock.should_receive(:late_handler_called).with(6).once.ordered

            process_events
            execution_engine.remove_propagation_handler(id)
            execution_engine.remove_propagation_handler(late_id)
            process_events
        end
    end

    def test_add_propagation_handlers_accepts_method_object
        FlexMock.use do |mock|
            handler = PropagationHandlerTest.new(plan, mock)
            id = execution_engine.add_propagation_handler(type: :external_events, &handler.method(:handler))

            mock.should_receive(:called).with(plan).twice
            process_events
            process_events
            execution_engine.remove_propagation_handler id
            process_events

            assert_equal(2, handler.event.history.size)
        end
    end

    def test_add_propagation_handler_validates_arity
        # Validate the arity
        assert_raises(ArgumentError) do
            execution_engine.add_propagation_handler { |plan, failure| mock.called(plan) }
        end

        process_events
    end

    def test_propagation_handlers_raises_on_error
        FlexMock.use do |mock|
            execution_engine.add_propagation_handler do |plan|
                mock.called
                raise SpecificException
            end
            mock.should_receive(:called).once
            assert_raises(SpecificException) { process_events }
        end
    end

    def test_propagation_handlers_disabled_on_error
        Roby.logger.level = Logger::FATAL
        FlexMock.use do |mock|
            execution_engine.add_propagation_handler on_error: :disable do |plan|
                mock.called
                raise
            end
            mock.should_receive(:called).once
            process_events
            process_events
        end
    end

    def test_propagation_handlers_ignore_on_error
        spy = flexmock { |s| s.should_receive(:called).twice }

        handler = execution_engine.add_propagation_handler on_error: :ignore do |plan|
            spy.called
            raise
        end
        inhibit_fatal_messages { process_events }
        inhibit_fatal_messages { process_events }
    ensure
        execution_engine.remove_propagation_handler(handler) if handler
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
	assert_equal(nil, context)

	step = [g2, [], nil, ev, [], nil]
	source_events, source_generators, context = execution_engine.prepare_propagation(nil, false, step)
	assert_equal([g2].to_set, source_generators)
	assert_equal([ev].to_set, source_events)
	assert_equal(nil, context)
    end

    def test_next_step
	# For the test to be valid, we need +pending+ to have a deterministic ordering
	# Fix that here
	e1, e2, e3 = EventGenerator.new(true), EventGenerator.new(true), EventGenerator.new(true)
	plan.add [e1, e2, e3]

        pending = Array.new
	def pending.each_key; each { |(k, v)| yield(k) } end
	def pending.delete(ev)
            value = find { |(k, v)| k == ev }.last
            delete_if { |(k, v)| k == ev }
            value
        end

        # If there is no precedence, the order is determined by
        # forwarding/signalling and/or step_id
        pending.clear
	pending << [e1, [0, nil, []]] << [e2, [1, [], nil]]
	assert_equal(e2, execution_engine.next_event(pending).first)
        pending.clear
	pending << [e1, [1, [], nil]] << [e2, [0, [], nil]]
	assert_equal(e2, execution_engine.next_event(pending).first)

        # If there *is* a precedence relation, we must follow it
        pending.clear
	pending << [e1, [0, [], nil]] << [e2, [1, [], nil]]

	e1.add_precedence e2
	assert_equal(e1, execution_engine.next_event(pending).first)
	e1.remove_precedence e2
	e2.add_precedence e1
	assert_equal(e2, execution_engine.next_event(pending).first)
    end

    def test_delay
        time_proxy = flexmock(Time)
        current_time = Time.now + 5
        time_proxy.should_receive(:now).and_return { current_time }

        plan.add_mission_task(t = Tasks::Simple.new)
        e = EventGenerator.new(true)
        t.event(:start).signals e, delay: 0.1
        execution_engine.once { t.start! }
        process_events
        assert(!e.emitted?)
        current_time += 0.2
        process_events
        assert(e.emitted?)
    end

    def test_delay_with_unreachability
        time_proxy = flexmock(Time)
        current_time = Time.now + 5
        time_proxy.should_receive(:now).and_return { current_time }

        source, sink0, sink1 = prepare_plan permanent: 3, model: Tasks::Simple
        source.start_event.signals sink0.start_event, delay: 0.1
        source.start_event.signals sink1.start_event, delay: 0.1
        source.start!
        assert(!sink0.start_event.emitted?)
        assert(!sink1.start_event.emitted?)

        plan.remove_task(sink0)
        inhibit_fatal_messages { sink1.failed_to_start!("test") }
        assert(sink0.start_event.unreachable?)
        assert(sink1.start_event.unreachable?)
        assert(! execution_engine.delayed_events.
               find { |_, _, _, target, _| target == sink0.start_event })
        assert(! execution_engine.delayed_events.
               find { |_, _, _, target, _| target == sink1.start_event })

        current_time += 0.1
        # Avoid unnecessary error messages
        plan.unmark_permanent_task(sink0)
        plan.unmark_permanent_task(sink1)
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
	    t.start!(42)
	end
    end

    def test_default_task_ordering
	a = Tasks::Simple.new_submodel do
	    event :intermediate
	end.new(id: 'a')

	plan.add_mission_task(a)
	a.depends_on(b = Tasks::Simple.new(id: 'b'))

	b.success_event.forward_to a.intermediate_event
	b.success_event.forward_to a.success_event

	FlexMock.use do |mock|
            b.success_event.on { |ev| mock.child_success }
	    a.intermediate_event.on { |ev| mock.parent_intermediate }
	    a.success_event.on { |ev| mock.parent_success }
	    mock.should_receive(:child_success).once.ordered
	    mock.should_receive(:parent_intermediate).once.ordered
	    mock.should_receive(:parent_success).once.ordered
	    a.start!
	    b.start!
	    b.success!
	end
    end

    def test_process_events_diamond_structure
	a = Tasks::Simple.new_submodel do
	    event :child_success
	    event :child_stop
	    forward child_success: :child_stop
	end.new(id: 'a')

	plan.add_mission_task(a)
	a.depends_on(b = Tasks::Simple.new(id: 'b'))

	b.success_event.forward_to a.child_success_event
	b.stop_event.forward_to a.child_stop_event

	FlexMock.use do |mock|
	    a.child_stop_event.on { |ev| mock.stopped }
	    mock.should_receive(:stopped).once.ordered
	    a.start!
	    b.start!
	    b.success!
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
	    signal.signals   sink

	    seeds = execution_engine.gather_propagation do
		forward.call(24)
		signal.call(42)
	    end
	    mock.should_receive(:command_called).with([42]).once.ordered
	    mock.should_receive(:handler_called).with([42, 24]).once.ordered
	    execution_engine.event_propagation_phase(seeds)
	end
    end

    def test_add_framework_errors
	# Shut up the logger in this test
	Roby.logger.level = Logger::FATAL
	exception = begin; raise RuntimeError
		    rescue; $!
		    end

	Roby.app.abort_on_application_exception = false
	execution_engine.add_framework_error(exception, :exceptions)

	Roby.app.abort_on_application_exception = true
	assert_raises(RuntimeError) { execution_engine.add_framework_error(exception, :exceptions) }
    end

    def test_event_loop
        plan.add_mission_task(start_node = EmptyTask.new)
        next_event = [ start_node, :start ]
        plan.add_mission_task(if_node    = ChoiceTask.new)
        start_node.stop_event.on { |ev| next_event = [if_node, :start] }
	if_node.stop_event.on { |ev| }
            
        execution_engine.add_propagation_handler(type: :external_events) do |plan|
            next unless next_event
            task, event = *next_event
            next_event = nil
            task.event(event).call(nil)
        end
        process_events
        assert(start_node.finished?)
	
        process_events
	assert(if_node.finished?)
    end

    def test_every
	# Check that every(cycle_length) works fine
	execution_engine.run

	samples = []
	id = execution_engine.every(0.1) do
	    samples << execution_engine.cycle_start
	end
	sleep(1)
	execution_engine.remove_periodic_handler(id)
	size = samples.size
	assert(size > 2, "expected 2 samples, got #{samples.size}")

	samples.each_cons(2) do |a, b|
	    assert_in_delta(0.1, b - a, 0.001)
	end

	# Check that no samples have been added after the 'remove_periodic_handler'
	assert_equal(size, samples.size)
    end

    def test_once_blocks_are_called_by_proces_events
	FlexMock.use do |mock|
	    execution_engine.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	end
    end
    def test_once_blocks_are_called_only_once
	FlexMock.use do |mock|
	    execution_engine.once { mock.called }
	    mock.should_receive(:called).once
	    process_events
	    process_events
	end
    end

    def test_failing_once
        spy = flexmock
        spy.should_receive(:called).once
        execution_engine.once { spy.called; raise }

        assert_raises(RuntimeError) do
            process_events
        end
    end

    class SpecificException < RuntimeError; end
    def test_unhandled_event_command_exception
	Roby.app.abort_on_exception = true

	# Test that the event is not pending if the command raises
	model = Tasks::Simple.new_submodel do
	    event :start do |context|
		raise SpecificException, "bla"
            end
	end
	plan.add_permanent_task(t = model.new(id: 1))

	assert_original_error(SpecificException, CommandFailed) { t.start! }
	assert(!t.event(:start).pending?)

	# Check that the propagation is pruned if the command raises
	t = nil
	FlexMock.use do |mock|
	    t = Tasks::Simple.new_submodel do
		event :start do |context|
		    mock.command_called
		    raise SpecificException, "bla"
		    start_event.emit
                end
		on(:start) { |ev| mock.handler_called }
	    end.new(id: 2)
	    plan.add_permanent_task(t)

	    mock.should_receive(:command_called).once
	    mock.should_receive(:handler_called).never

	    execution_engine.once { t.start!(nil) }
	    assert_original_error(SpecificException, CommandFailed) { process_events }
	    assert(!t.event(:start).pending)
            assert(t.failed_to_start?)
	end

	# Check that the task gets garbage collected in the process
	assert(! plan.has_task?(t))
    end

    def test_unhandled_event_handler_exception
        # To stop the error message
	Roby.logger.level = Logger::FATAL

	model = Tasks::Simple.new_submodel do
	    on :start do |event|
		raise SpecificException, "bla"
            end
	end

        plan.add_permanent_task(t = model.new)
        assert_event_emission(t.failed_event) do
            t.start!
        end
        assert_kind_of SpecificException, t.failure_reason

	# Check that the task has been garbage collected in the process
	assert(! plan.has_task?(t))
	assert(t.failed?)
    end


    def apply_check_structure(&block)
	Plan.structure_checks.clear
	Plan.structure_checks << lambda(&block)
	process_events
    ensure
	Plan.structure_checks.clear
    end

    def test_check_structure_handlers_are_propagated_twice
        # First time, we don't do anything. Second time, we return some filtered
        # fatal errors and verify that they are handled
	Plan.structure_checks.clear
        t0, t1, t2 = prepare_plan add: 3
        t1.depends_on t0
        errors = Hash[LocalizedError.new(t0).to_execution_exception => [t1]]
        plan.structure_checks.clear
        handler = proc { errors }
	Plan.structure_checks << handler

        execution_engine = flexmock(self.execution_engine)
        execution_engine.should_receive(:propagate_exceptions).with([]).and_return([])
        execution_engine.should_receive(:propagate_exceptions).with(errors).once
        execution_engine.should_receive(:remove_inhibited_exceptions).with(errors).
            and_return([[LocalizedError.new(t0), [t2]]])
        assert_equal [[LocalizedError.new(t0), [t2]]],
            execution_engine.compute_fatal_errors([])
    ensure
        Plan.structure_checks.delete(handler) if handler
    end

    def test_at_cycle_end
	# Shut up the logger in this test
	Roby.logger.level = Logger::FATAL
        Roby.app.abort_on_application_exception = false

        FlexMock.use do |mock|
            mock.should_receive(:before_error).at_least.once
            mock.should_receive(:after_error).never
            mock.should_receive(:called).at_least.once

            execution_engine.at_cycle_end do
		mock.before_error
		raise
		mock.after_error
            end

            execution_engine.at_cycle_end do
		mock.called
		unless execution_engine.quitting?
		    execution_engine.quit
		end
            end
            execution_engine.run
            execution_engine.join
        end
    end

    def test_inside_outside_control
	# First, no control thread
	assert(execution_engine.inside_control?)
	assert(execution_engine.outside_control?)

	# Add a fake control thread
	begin
	    execution_engine.thread = Thread.main
	    assert(execution_engine.inside_control?)
	    assert(!execution_engine.outside_control?)

	    t = Thread.new do
		assert(!execution_engine.inside_control?)
		assert(execution_engine.outside_control?)
	    end
	    t.value
	ensure
	    execution_engine.thread = nil
	end

	# .. and test with the real one
	execution_engine.run
	execution_engine.execute do
	    assert(execution_engine.inside_control?)
	    assert(!execution_engine.outside_control?)
	end
	assert(!execution_engine.inside_control?)
	assert(execution_engine.outside_control?)
    end

    def test_execute
	# Set a fake control thread
	execution_engine.thread = Thread.main

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
	    while !t.stop?; sleep(0.1) end
	    mock.main_before
	    assert(t.alive?)
            # We use execution_engine.process_events as we are making the execution_engine
            # believe that it is running while it is not
	    execution_engine.process_events
	    mock.main_after
	    t.join

	    assert_equal(42, returned_value)
	end

    ensure
	execution_engine.thread = nil
    end

    def test_execute_error
	assert(!execution_engine.thread)
	# Set a fake control thread
	execution_engine.thread = Thread.main
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
	while !t.stop?; sleep(0.1) end
        assert(t.alive?)
        # We use execution_engine.process_events as we are making the execution_engine
        # believe that it is running while it is not
	execution_engine.process_events
	t.join

	assert_kind_of(ArgumentError, returned_value)
	assert(!execution_engine.quitting?)

    ensure
	execution_engine.thread = nil
    end
    
    def test_wait_until
	# Set a fake control thread
	execution_engine.thread = Thread.main

	plan.add_permanent_task(task = Tasks::Simple.new)
	t = Thread.new do
	    execution_engine.wait_until(task.event(:start)) do
		task.start!
	    end
	end

	while !t.stop?; sleep(0.1) end
        # We use execution_engine.process_events as we are making the execution_engine
        # believe that it is running while it is not
	execution_engine.process_events
	t.value

    ensure
	execution_engine.thread = nil
    end
 
    def test_wait_until_unreachable
	# Set a fake control thread
	execution_engine.thread = Thread.main

	plan.add_permanent_task(task = Tasks::Simple.new)
	t = Thread.new do
	    begin
		execution_engine.wait_until(task.event(:success)) do
		    task.start!
                    task.stop!
		end
	    rescue Exception => e
		e
	    end
	end

        # Wait for #wait_until, in the thread, to wait for the main thread
	while !t.stop?; sleep(0.1) end
        # And process the events
        with_log_level(Roby, Logger::FATAL) do
            # We use execution_engine.process_events as we are making the execution_engine
            # believe that it is running while it is not
            execution_engine.process_events
        end

	result = t.value
	assert_kind_of(UnreachableEvent, result)
	assert_equal(task.event(:success), result.failed_generator)

    ensure
	execution_engine.thread = nil
    end
    
    def test_stats
	time_events = [:actual_start, :events, :structure_check, :exception_propagation, :exception_fatal, :garbage_collect, :application_errors, :ruby_gc, :sleep, :end]
	10.times do
            FlexMock.use(execution_engine) do |mock|
                mock.should_receive(:cycle_end).and_return do |stats|
                    timepoints = stats.slice(*time_events)
                    assert(timepoints.all? { |name, d| d > 0 })

                    sorted_by_time = timepoints.sort_by { |name, d| d }
                    sorted_by_name = timepoints.sort_by { |name, d| time_events.index(name) }
                    sorted_by_time.each_with_index do |(name, d), i|
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

            yield if block_given?

            execution_engine.garbage_collect
            execution_engine.garbage_collect
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
        dependency_chain m1, t1, t2
        dependency_chain m2, t1
        dependency_chain m3, t2
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
	t1.start!
	assert_finalizes(plan, []) do
            execution_engine.force_gc_on(t1)
	    execution_engine.garbage_collect
	end
	assert(t1.event(:stop).pending?)

	assert_finalizes(plan, [t1, t2]) do
	    # This stops the mission, which will be automatically discarded
            t1.stop_event.emit
	end
    end

    def test_gc_ignores_incoming_events
	Roby::Plan.logger.level = Logger::WARN
	a, b = prepare_plan discover: 2, model: Tasks::Simple
        a.stop_event.signals b.stop_event
	a.start!

	process_events
	process_events
	assert(!a.plan)
	assert(!b.plan)
	assert(!b.event(:start).emitted?)
    end

    # Test a setup where there is both pending tasks and running tasks. This
    # checks that #stop! is called on all the involved tasks. This tracks
    # problems related to bindings in the implementation of #garbage_collect:
    # the killed task bound to the Roby.once block must remain the same.
    def test_gc_stopping
	Roby::Plan.logger.level = Logger::WARN
	running_task = nil
	FlexMock.use do |mock|
	    task_model = Task.new_submodel do
		event :start, command: true
		event :stop do |context|
		    mock.stop(self)
		end
	    end

	    running_tasks = (1..5).map do
		task_model.new
	    end

	    plan.add(running_tasks)
	    t1, t2 = Roby::Task.new, Roby::Task.new
	    t1.depends_on t2
	    plan.add(t1)

	    running_tasks.each do |t|
		t.start!
		mock.should_receive(:stop).with(t).once
	    end
		
	    execution_engine.garbage_collect
	    process_events

	    assert(!plan.has_task?(t1))
	    assert(!plan.has_task?(t2))
	    running_tasks.each do |t|
		assert(t.finishing?)
		t.stop_event.emit
	    end

	    execution_engine.garbage_collect
	    running_tasks.each do |t|
		assert(!plan.has_task?(t))
	    end
	end

    ensure
	running_task.stop_event.emit if running_task && !running_task.finished?
    end

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

	plan.remove_task(t)
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

    def test_garbage_collect_weak_relations
        planning, planned, influencing = prepare_plan discover: 3, model: Tasks::Simple

        # Create a cycle with a weak relation
        planned.planned_by planning
        influencing.depends_on planned
        planning.add_weak_test influencing

        planned.start!
        planning.start!
        influencing.start!
        
        process_events
	assert(plan.tasks.empty?)
    end

    def test_mission_failed
	model = Tasks::Simple.new_submodel do
	    event :specialized_failure, command: true
	    forward specialized_failure: :failed
	end

	task = prepare_plan missions: 1, model: model
	task.start!
        
        error = inhibit_fatal_messages do
            assert_raises(Roby::MissionFailedError) { task.specialized_failure! }
        end
	
	assert_kind_of(Roby::MissionFailedError, error)
	assert_equal(task.event(:specialized_failure).last, error.failure_point)
        Roby.format_exception error
    end

    def test_forward_signal_ordering
        100.times do
            stop_called = false
            source = Tasks::Simple.new(id: 'source')
            target = Tasks::Simple.new_submodel do
                event :start do |context|
                    if !stop_called
                        raise ArgumentError, "ordering failed"
                    end
                    start_event.emit
                end
            end.new(id: 'target')
            plan.add(source)
            plan.add(target)

            source.success_event.signals target.start_event
            source.stop_event.on do |ev|
                stop_called = true
            end
            source.start!
            source.success_event.emit
            assert(target.running?)
            target.stop!
        end
    end

    def test_delayed_block
        time_mock = flexmock(Time)
        time = Time.now
        time_mock.should_receive(:now).and_return { time }

        recorder = flexmock
        recorder.should_receive(:triggered).once.with(time + 6)
        execution_engine.delayed(5) { recorder.triggered(Time.now) }
        process_events
        time = time + 2
        process_events
        time = time + 4
        process_events
    end

    def test_one_can_add_errors_during_garbage_collection
        plan.add(task = Roby::Tasks::Simple.new)
        task.stop_event.when_unreachable do
            execution_engine.add_error LocalizedError.new(task)
        end
        inhibit_fatal_messages { process_events }
    end

    class SpecializedError < LocalizedError; end

    def test_pass_exception_ignores_a_handler
        mock = flexmock
        klass = Task.new_submodel
        klass.on_exception(SpecializedError) do |exception|
            mock.called
            pass_exception
        end

        plan.add(task  = klass.new)
        error = ExecutionException.new(SpecializedError.new(task))
        mock.should_receive(:called).once
        assert(!task.handle_exception(error))
    end

    def test_task_handlers_are_called_in_the_inverse_declaration_order
	mock = flexmock

        received_handler2 = false
        klass = Task.new_submodel do 
            on_exception(SpecializedError) do |exception|
                mock.handler1(exception, self)
            end
            on_exception(SpecializedError) do |exception|
                mock.handler2(exception, self)
                pass_exception
            end
        end

        plan.add(task  = klass.new)
        error = ExecutionException.new(SpecializedError.new(task))
        mock.should_receive(:handler2).with(error, task).once.ordered
        mock.should_receive(:handler1).with(error, task).once.ordered
        assert task.handle_exception(error)
    end

    def make_task_with_handler(exception_matcher, mock)
        Task.new_submodel do 
            on_exception(exception_matcher) do |exception|
                mock.handler(exception, self)
            end
        end.new
    end

    def test_it_filters_handlers_on_the_exception_model
        mock = flexmock

        t1, t2 = prepare_plan add: 2
        t0 = make_task_with_handler(SpecializedError, mock)
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))
        mock.should_receive(:handler).once.
            with(on { |e| e.trace == [t2, t1, t0] && e.origin == t2 }, t0)
        assert_equal([], execution_engine.propagate_exceptions([error]))
    end

    def test_it_ignores_handlers_that_do_not_match_the_filter
        t1, t2 = prepare_plan add: 2
        t0 = make_task_with_handler(CodeError, nil)
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))

        remaining = execution_engine.propagate_exceptions([error])
        assert_equal 1, remaining.size
        remaining_error, affected_tasks = remaining.first
        assert_equal error, remaining_error
        assert_equal error.trace.to_set, affected_tasks.to_set
    end

    def test_it_does_not_call_global_handlers_if_the_exception_is_handled_by_a_task
        mock = flexmock

        t1, t2 = prepare_plan add: 3
        t0 = make_task_with_handler(SpecializedError, mock)
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))
        plan.on_exception(SpecializedError) do |p, e|
            mock.handler(e, p)
        end
        mock.should_receive(:handler).with(error, t0).once
        mock.should_receive(:handler).with(error, plan).never
        assert_equal([], execution_engine.propagate_exceptions([error]))
    end

    def test_it_notifies_about_exceptions_handled_by_a_task
        mock = flexmock
        task_model = Roby::Task.new_submodel do
            on_exception(SpecializedError) { |e| }
        end
        plan.add(t0 = task_model.new)
        plan.add(t1 = Tasks::Simple.new)
        t0.depends_on(t1)

        error = ExecutionException.new(SpecializedError.new(t1))
        execution_engine.on_exception do |kind, error, involved_objects|
            mock.notified(kind, error.exception, involved_objects.to_set)
        end
        mock.should_receive(:notified).once.
            with(Roby::ExecutionEngine::EXCEPTION_HANDLED, error.exception, Set[t0])
        assert_equal([], execution_engine.propagate_exceptions([error]))
    end

    def test_it_notifies_about_exceptions_handled_by_the_plan
        mock = flexmock
        t0, t1 = prepare_plan add: 3
        t0.depends_on(t1)

        error = ExecutionException.new(SpecializedError.new(t1))
        plan.on_exception(SpecializedError) {}
        execution_engine.on_exception do |kind, error, involved_objects|
            mock.notified(kind, error.exception, involved_objects.to_set)
        end
        mock.should_receive(:notified).once.
            with(Roby::ExecutionEngine::EXCEPTION_HANDLED, error.exception, Set[plan])
        assert_equal([], execution_engine.propagate_exceptions([error]))
    end

    def test_it_uses_global_handlers_to_filter_exceptions_that_have_not_been_handled_by_a_task
        mock = flexmock

        t0, t1, t2 = prepare_plan add: 3
        dependency_chain(t0, t1, t2)

        error = ExecutionException.new(SpecializedError.new(t2))
        plan.on_exception(SpecializedError) do |p, e|
            mock.handler(e, p)
        end
        mock.should_receive(:handler).with(error, plan).once
        assert_equal([], execution_engine.propagate_exceptions([error]))
    end

    def dependency_chain(*tasks)
        plan.add(tasks.first)
        tasks.each_cons(2) do |from, to|
            from.depends_on to
        end
    end

    def test_propagate_exceptions_forked_propagation
	# We build a 0 -> 1 -> 2 3 -> 2 task tree with
	# 0 being able to handle the exception and 1, 3 not

	mock = flexmock

        t1, t2, t3 = prepare_plan add: 3
        t0 = Task.new_submodel do 
            on_exception(Roby::CodeError) do |exception|
                mock.handler(exception, exception.trace, self)
            end
        end.new
        dependency_chain t0, t1, t2
        dependency_chain t3, t2

        mock.should_receive(:handler).
            with(ExecutionException, [t2, t1, t0], t0).once
        flexmock(execution_engine).should_receive(:handled_exception).
            with(on { |e| e.trace == [t2, t1, t0] }, t0)

        error = ExecutionException.new(CodeError.new(nil, t2))
        fatal = execution_engine.propagate_exceptions([error])
        assert_equal 1, fatal.size

        exception, affected_tasks = fatal.first
        assert_equal [t2, t3], exception.trace
        assert_equal [t3], affected_tasks
    end

    def test_propagate_exceptions_diamond_propagation
        mock = flexmock

        t11, t12, t2 = prepare_plan add: 3

        t0 = Task.new_submodel do 
            on_exception(Roby::LocalizedError) do |exception|
                mock.handler(exception, self)
            end
        end.new
        dependency_chain(t0, t11, t2)
        dependency_chain(t0, t12, t2)

        error = ExecutionException.new(LocalizedError.new(t2))
        mock.should_receive(:handler).once.
            with(on { |e| e.trace.flatten.to_set == [t0, t2, t12, t11].to_set && e.origin == t2 }, t0)
        assert_equal([], execution_engine.propagate_exceptions([error]))
    end

    def test_event_propagation_with_exception
	ev = EventGenerator.new do |context|
	    raise RuntimeError
	    ev.emit(context)
	end
	plan.add(ev)
	assert_original_error(RuntimeError, CommandFailed) { ev.call(nil) }
	assert(!ev.emitted?)

	# Check that the event is emitted anyway
	ev = EventGenerator.new do |context|
	    ev.emit(context)
	    raise RuntimeError
	end
	plan.add(ev)
	assert_original_error(RuntimeError, CommandFailed) { ev.call(nil) }
	assert(ev.emitted?)

	# Check signalling
	ev = EventGenerator.new do |context|
	    ev.emit(context)
	    raise RuntimeError
	end
	plan.add(ev)
	ev2 = EventGenerator.new(true)
	ev.signals ev2

	assert_original_error(RuntimeError, CommandFailed) { ev.call(nil) }
	assert(ev.emitted?)
	assert(ev2.emitted?)

	# Check event handlers
	FlexMock.use do |mock|
	    ev = EventGenerator.new(true)
	    plan.add(ev)
	    ev.on { |ev| mock.handler ; raise RuntimeError }
	    ev.on { |ev| mock.handler }
	    mock.should_receive(:handler).twice
	    assert_original_error(RuntimeError, EventHandlerError) { ev.call }
	end
    end

    # Tests exception handling mechanism during event propagation
    def test_task_propagation_with_exception
	Roby.app.abort_on_exception = true
	Roby::ExecutionEngine.logger.level = Logger::FATAL + 1

	task = Tasks::Simple.new_submodel do
	    event :start do |context|
		start_event.emit
		raise RuntimeError, "failed"
            end
	end.new(id: 'child')

	FlexMock.use do |mock|
	    parent = Tasks::Simple.new_submodel do
		on_exception ChildFailedError do |exception|
		    mock.exception
		    task.pass_exception
		end
	    end.new(id: 'parent')
	    mock.should_receive(:exception).once

	    parent.depends_on task
	    plan.add_permanent_task(parent)
            
	    execution_engine.once { parent.start!; task.start! }

	    mock.should_receive(:other_once_handler).once
	    mock.should_receive(:other_event_processing).once
	    execution_engine.once { mock.other_once_handler }
	    execution_engine.add_propagation_handler(type: :external_events) { |plan| mock.other_event_processing }

            assert_raises(Roby::ChildFailedError) do
		process_events
	    end
	end
	assert(task.event(:start).emitted?)
    end

    def test_exception_argument_count_validation
        assert_raises(ArgumentError) do
            Task.new_submodel.on_exception(RuntimeError) do |a, b|
            end
        end
        Task.new_submodel.on_exception(RuntimeError) do |_|
        end

        assert_raises(ArgumentError) do |a, b|
            plan.on_exception(RuntimeError) do |_|
            end
        end
        plan.on_exception(RuntimeError) do |_, _|
        end
    end

    def test_error_handling_relation(error_event = :failed)
	task_model = Tasks::Simple.new_submodel do
	    event :blocked
	    forward blocked: :failed
	end

	parent, (child, *repair_tasks) = prepare_plan permanent: 1, add: 3, model: task_model
	parent.depends_on child
	child.event(:failed).handle_with repair_tasks[0]

	parent.start!
	child.start!
        child.event(error_event).emit

	exceptions = plan.check_structure
        assert execution_engine.remove_inhibited_exceptions(exceptions).empty?
	assert_equal([], execution_engine.propagate_exceptions(exceptions))

        repairs = child.find_all_matching_repair_tasks(child.terminal_event)
        assert_equal 1, repairs.size
        repair_task = repairs.first

        # Verify that both the repair and root tasks are not garbage collected
	process_events
	assert(repair_task.running?)

	# Make the "repair task" finish, but do not repair the plan.
	# propagate_exceptions must not add a new repair
        inhibit_fatal_messages do
            assert_raises(ChildFailedError) do
                repair_task.success!
            end
        end

    ensure
	parent.remove_child child if child
    end

    def test_error_handling_relation_generalization
	test_error_handling_relation(:blocked)
    end

    def test_error_handling_relation_with_as_plan
        model = Tasks::Simple.new_submodel do
            def self.as_plan
                new(id: 10)
            end
        end
        task = prepare_plan add: 1, model: Tasks::Simple
        child = task.failed_event.handle_with(model)
        assert_kind_of model, child
        assert_equal 10, child.arguments[:id]
    end

    def test_mission_exceptions
	mission = prepare_plan missions: 1, model: Tasks::Simple
	mission.start!
        error = inhibit_fatal_messages do
            assert_raises(MissionFailedError) { mission.failed_event.emit }
        end

	assert_kind_of(Roby::MissionFailedError, error)
    end

    def test_command_failed_formatting
        plan.add(task = Roby::Task.new)
        Roby.format_exception(CommandFailed.new(RuntimeError.new("message"), task.start_event))
    end

    def test_emission_failed_formatting
        plan.add(task = Roby::Task.new)
        Roby.format_exception(EmissionFailed.new(RuntimeError.new("message"), task.start_event))
    end

    def test_event_handler_error_formatting
        plan.add(task = Roby::Task.new)
        Roby.format_exception(EventHandlerError.new(RuntimeError.new("message"), task.start_event))
    end

    def test_nonfatal_exception_handling
        task_model = Tasks::Simple.new_submodel
        plan.add_permanent_task(t = task_model.new)
        t.start!

        mock = flexmock
        execution_engine.on_exception do |kind, error, involved_objects|
            mock.notified(kind, error.exception, involved_objects.to_set)
        end
        mock.should_receive(:notified).once.
            with(ExecutionEngine::EXCEPTION_NONFATAL, PermanentTaskError, [t].to_set)

        t.failed_event.emit
    end

    def test_fatal_exception_handling
        task_model = Tasks::Simple.new_submodel do
            event :intermediate do |context|
                intermediate_event.emit
            end
        end
        
        t1, t2, t3 = prepare_plan add: 3, model: task_model
        t1.depends_on t2
        t2.depends_on t3, failure: [:intermediate]

        t1.start!
        t2.start!
        t3.start!

        mock = flexmock
        execution_engine.on_exception do |kind, error, involved_objects|
            mock.notified(kind, error.exception, involved_objects.to_set)
        end
        mock.should_receive(:notified).once.
            with(ExecutionEngine::EXCEPTION_FATAL, ChildFailedError, [t1, t2, t3].to_set)

        assert_raises(ChildFailedError) do
            t3.intermediate!
        end
    end

    def test_permanent_task_errors_are_nonfatal
        task = prepare_plan permanent: 1, model: Tasks::Simple

        mock = flexmock
        mock.should_receive(:called).once.with(false)

        plan.on_exception(PermanentTaskError) do |plan, error|
            plan.unmark_permanent(error.task)
            mock.called(error.fatal?)
        end

        task.start!
        task.stop!
    end

    def test_it_propagates_exceptions_only_through_the_listed_parents
        mock = flexmock
        task_model = Task.new_submodel do
            on_exception LocalizedError do |error|
                mock.called(self)
                pass_exception
            end
        end
        a0, a1 = prepare_plan add: 2, model: task_model
        plan.add(b = Roby::Task.new)
        a0.depends_on b
        a1.depends_on b
        mock.should_receive(:called).with(a0).once
        mock.should_receive(:called).with(a1).never
        execution_engine.propagate_exceptions([[b.to_execution_exception, [a0]]])
    end

    def test_the_propagation_is_robust_to_badly_specified_parents
        plan.add(parent = Roby::Task.new)
        child = parent.depends_on(Roby::Task.new)
        plan.add(task = Roby::Task.new)

        error = LocalizedError.new(child).to_execution_exception
        result = inhibit_fatal_messages do
            execution_engine.propagate_exceptions([[error, [task]]])
        end
        assert_equal error, result.first.first
        assert_equal [parent, child].to_set, result.first.last.to_set
    end

    def test_garbage_collection_calls_are_propagated_first_while_quitting
        obj = Class.new do
            def stopped?; @stop end
            def stop; @stop = true end
        end.new
        flexmock(obj).should_receive(:stop).once.
            pass_thru

        task_model = Class.new(Roby::Task) do
            argument :obj

            event :start, controlable: true
            event :stop do |_|
                obj.stop
                stop_event.emit
            end
        end
        plan.add(task = task_model.new(obj: obj))
        task.start!
        plan.execution_engine.at_cycle_begin do
            if !obj.stopped?
                obj.stop
            end
        end
        plan.execution_engine.quit
        while task.running?
            plan.execution_engine.process_events
        end
    end
end

