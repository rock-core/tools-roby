module Roby
    module PlanCommonBehavior
        def assert_task_state(task, state)
            if state == :removed
                assert(!plan.has_task?(task), "task was meant to be removed, but Plan#has_task? still returns true")
                assert(!plan.permanent_task?(task), "task was meant to be removed, but Plan#permanent_task? still returns true")
                assert(!plan.mission_task?(task), "task was meant to be removed, but Plan#mission_task? returns true")
                assert(!task.mission?, "task was meant to be removed, but Task#mission? returns true")
                assert_nil task.plan, "task was meant to be removed, but PlanObject#plan returns a non-nil value"
            else
                assert_equal(plan, task.plan, "task was meant to be included in a plan but PlanObject#plan returns nil")
                assert(plan.has_task?(task), "task was meant to be included in a plan but Plan#has_task? returned false")
                if state == :permanent
                    assert(plan.permanent_task?(task), "task was meant to be permanent but Plan#permanen_taskt? returned false")
                else
                    assert(!plan.permanent_task?(task), "task was not meant to be permanent but Plan#permanen_taskt? returned true")
                end

                if state == :mission
                    assert(plan.mission_task?(task), "task was meant to be a mission, but Plan#mission_task? returned false")
                    assert(task.mission?, "task was meant to be a mission, but Task#mission_task? returned false")
                elsif state == :permanent
                    assert(!plan.mission_task?(task), "task was meant to be permanent but Plan#mission_task? returned true")
                    assert(!task.mission?, "task was meant to be permanent but Task#mission? returned true")
                elsif state == :normal
                    assert(!plan.mission_task?(task), "task was meant to be permanent but Plan#mission_task? returned true")
                    assert(!task.mission?, "task was meant to be permanent but Task#mission? returned true")
                end
            end
        end
        def assert_event_state(event, state)
            if state == :removed
                assert(!plan.has_free_event?(event), "event was meant to be removed, but Plan#has_free_event? still returns true")
                assert(!plan.permanent_event?(event), "event was meant to be removed, but Plan#permanent_event? still returns true")
                assert_nil event.plan, "event was meant to be removed, but PlanObject#plan returns a non-nil value"
            else
                assert_equal(plan, event.plan, "event was meant to be included in a plan but PlanObject#plan returns nil")
                assert(plan.has_free_event?(event), "event was meant to be included in a plan but Plan#has_free_event? returned false")
                if state == :permanent
                    assert(plan.permanent_event?(event), "event was meant to be permanent but Plan#permanent_event? returned false")
                else
                    assert(!plan.permanent_event?(event), "event was not meant to be permanent but Plan#permanent_event? returned true")
                end
            end
        end

        def test_add_task
            plan.add(t = Task.new)
            assert_same t.relation_graphs, plan.task_relation_graphs
            assert_task_state(t, :normal)
            assert_equal plan, t.plan

            other_plan = Plan.new
            assert_raises(ModelViolation) { other_plan.add(t) }
            assert !other_plan.has_task?(t)
            assert_same t.relation_graphs, plan.task_relation_graphs
        end

        def test_add_plan
            t1, t2, t3 = (1..3).map { Task.new }
            ev = EventGenerator.new
            t1.depends_on t2
            t2.depends_on t3
            t1.stop_event.signals t3.start_event
            t3.stop_event.forward_to ev
            plan.add(t1)

            assert_equal [t1, t2, t3].to_set, plan.tasks
            expected = [t1, t2, t3].flat_map { |t| t.each_event.to_a }.to_set
            assert_equal expected, plan.task_events
            assert_equal [ev].to_set, plan.free_events
            assert t1.child_object?(t2, TaskStructure::Dependency)
            assert t2.child_object?(t3, TaskStructure::Dependency)
            assert t1.stop_event.child_object?(t3.start_event, EventStructure::Signal)
            assert t3.stop_event.child_object?(ev, EventStructure::Forwarding)
        end

        def test_removing_a_task_deregisters_it_from_the_plan
            t = prepare_plan add: 1
            assert_task_state(t, :normal)
            plan.remove_task(t)
            assert_task_state(t, :removed)
        end

        def test_add_mission_task
            plan.add_mission_task(t = Task.new)
            assert_task_state(t, :mission)
        end
        
        def test_unmark_mission_task
            plan.add_mission_task(t = Task.new)
            plan.unmark_mission_task(t)
            assert_task_state(t, :normal)
        end
        def test_removed_mission
            plan.add_mission_task(t = Task.new)
            plan.remove_task(t)
            assert_task_state(t, :removed)
        end

        def test_add_permanent_task
            plan.add_permanent_task(t = Task.new)
            assert_task_state(t, :permanent)
        end
        def test_unmark_permanent_task
            plan.add_permanent_task(t = Task.new)
            plan.unmark_permanent_task(t)
            assert_task_state(t, :normal)
        end
        def test_remove_permanent_task
            plan.add_permanent_task(t = Task.new)
            plan.remove_task(t)
            assert_task_state(t, :removed)
        end

        def test_add_event
            plan.add(ev = EventGenerator.new)
            assert_event_state(ev, :normal)
        end
        def test_remove_free_event
            plan.add(ev = EventGenerator.new)
            plan.remove_free_event(ev)
            assert_event_state(ev, :removed)
        end
        def test_add_permanent_event
            plan.add_permanent_event(ev = EventGenerator.new)
            assert_event_state(ev, :permanent)
        end
        def test_unmark_permanent_event
            plan.add_permanent_event(ev = EventGenerator.new)
            plan.unmark_permanent_event(ev)
            assert_event_state(ev, :normal)
        end

        def test_free_events
            t1, t2, t3 = (1..3).map { Task.new }
            plan.add_mission_task(t1)
            t1.depends_on t2
            assert_equal(plan, t2.plan)
            assert_equal(plan, t1.event(:start).plan)

            or_generator  = (t1.event(:stop) | t2.event(:stop))
            assert_equal(plan, or_generator.plan)
            assert(plan.has_free_event?(or_generator))
            or_generator.signals t3.event(:start)
            assert_equal(plan, t3.plan)

            and_generator = (t1.event(:stop) & t2.event(:stop))
            assert_equal(plan, and_generator.plan)
            assert(plan.has_free_event?(and_generator))
        end

        def test_plan_synchronization
            t1, t2 = prepare_plan tasks: 2

            plan.add_mission_task(t1)
            assert_equal(plan, t1.plan)
            t1.depends_on t2
            assert_equal(plan, t1.plan)
            assert_equal(plan, t2.plan)
            assert(plan.has_task?(t2))

            e = EventGenerator.new(true)
            t1.start_event.signals e
            assert_equal(plan, e.plan)
            assert(plan.has_free_event?(e))
        end

        # Checks that a garbage collected object (event or task) cannot be added back into the plan
        def test_removal_is_final
            t = Tasks::Simple.new
            e = EventGenerator.new(true)
            plan.real_plan.add [t, e]
            plan.real_plan.remove_task(t)
            plan.real_plan.remove_free_event(e)
            assert_raises(ArgumentError) { plan.add(t) }
            assert !plan.has_task?(t)
            assert_raises(ArgumentError) { plan.add(e) }
            assert !plan.has_free_event?(e)
        end

        def test_proxy_operator
            t = Tasks::Simple.new
            assert_same t, plan[t, create: false]

            assert plan.has_task?(t)
            assert_same t, plan[t, create: true]

            plan.remove_task(t)
            assert_raises(ArgumentError) { plan[t] }
        end

        def test_task_finalized_called_on_clear
            plan.add(task = Task.new)
            flexmock(task).should_receive(:finalized!).once
            task.each_event do |ev|
                flexmock(ev).should_receive(:finalized!).once
            end
            plan.clear
        end

        def test_event_finalized_called_on_clear
            plan.add(ev = EventGenerator.new)
            flexmock(ev).should_receive(:finalized!).once
            plan.clear
        end

        def test_task_events_are_added_and_removed
            plan.add(task = Tasks::Simple.new)
            task.each_event do |ev|
                assert(plan.has_task_event?(ev))
            end
            plan.remove_task(task)
            task.each_event do |ev|
                assert(!plan.has_task_event?(ev))
            end
        end

        def test_task_events_are_removed_on_clear
            plan.add(task = Tasks::Simple.new)
            plan.clear
            task.each_event do |ev|
                assert(!plan.has_task_event?(ev))
            end
        end
    end
end
