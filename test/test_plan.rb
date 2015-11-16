require 'roby/test/self'

module TC_PlanStatic
    include Roby
    def assert_task_state(task, state)
        assert_planobject_state(task, state)
        if state == :removed
            assert(!plan.mission?(task))
            assert(!task.mission?)
        else
            if state == :mission
                assert(plan.mission?(task))
                assert(task.mission?)
            elsif state == :permanent
                assert(!plan.mission?(task))
                assert(!task.mission?)
            elsif state == :normal
                assert(!plan.mission?(task))
                assert(!task.mission?)
            end
        end
    end
    def assert_planobject_state(obj, state)
        if state == :removed
            assert(!plan.include?(obj))
            assert(!plan.permanent?(obj))
            assert_equal(nil, obj.plan)
        else
            assert_equal(plan, obj.plan)
            assert(plan.include?(obj))
            if state == :permanent
                assert(plan.permanent?(obj))
            else
                assert(!plan.permanent?(obj))
            end
        end
    end

    def test_add_task
	plan.add(t = Task.new)
        assert_task_state(t, :normal)

        other_plan = Plan.new
        assert_raises(ModelViolation) { other_plan.add(t) }
    end
    def test_remove_task
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	t1.depends_on t2
	t1.signals(:stop, t3, :start)

	plan.add_mission(t1)
	plan.add_mission(t3)

	assert(!t1.leaf?)
	plan.remove_object(t2)
        assert_task_state(t2, :removed)
	assert(t1.leaf?(TaskStructure::Dependency))
	assert(!plan.include?(t2))

	assert(!t1.event(:stop).leaf?(EventStructure::Signal))
	plan.remove_object(t3)
        assert_task_state(t3, :removed)
	assert(t1.event(:stop).leaf?(EventStructure::Signal))
    end

    def test_add_mission
	plan.add_mission(t = Task.new)
        assert_task_state(t, :mission)
    end
    def test_unmark_mission
	plan.add_mission(t = Task.new)
	plan.unmark_mission(t)
        assert_task_state(t, :normal)
    end
    def test_removed_mission
	plan.add_mission(t = Task.new)
	plan.remove_object(t)
        assert_task_state(t, :removed)
    end

    def test_add_permanent
	plan.add_permanent(t = Task.new)
        assert_task_state(t, :permanent)
    end
    def test_unmark_permanent
	plan.add_permanent(t = Task.new)
	plan.unmark_permanent(t)
        assert_task_state(t, :normal)
    end
    def test_remove_permanent
	plan.add_permanent(t = Task.new)
	plan.remove_object(t)
        assert_task_state(t, :removed)
    end

    def test_add_event
	plan.add(ev = EventGenerator.new)
        assert_planobject_state(ev, :normal)
    end
    def test_remove_event
	plan.add(ev = EventGenerator.new)
	plan.remove_object(ev)
        assert_planobject_state(ev, :removed)
    end
    def test_add_permanent_event
	plan.add_permanent(ev = EventGenerator.new)
        assert_planobject_state(ev, :permanent)
    end
    def test_unmark_permanent_event
	plan.add_permanent(ev = EventGenerator.new)
	plan.unmark_permanent(ev)
        assert_planobject_state(ev, :normal)
    end

    # TODO: test that #remove_object removes the object from its relations
    # TODO: test that #add adds related objects

    #def test_discover
    #    t1, t2, t3, t4 = prepare_plan tasks: 4, model: Roby::Tasks::Simple
    #    t1.depends_on t2
    #    or_ev = OrGenerator.new
    #    t2.event(:start).signals or_ev
    #    or_ev.signals t3.event(:stop)
    #    t2.planned_by t4

    #    result = plan.discover(t1)
    #    assert_equal(plan, result)
    #    assert( plan.include?(t1) )
    #    assert( plan.include?(t2) )
    #    assert( plan.free_events.include?(or_ev))
    #    assert( !plan.include?(t3) ) # t3 not related because of task structure
    #    assert( plan.include?(t4) )

    #    # Discover t3 to help plan cleanup
    #    plan.discover(t3)

    #    # Discover an AndGenerator and not its sources. The sources
    #    # must be discovered automatically
    #    a, b = (1..2).map { EventGenerator.new(true) }
    #    and_event = a & b
    #    plan.discover(and_event)
    #    assert_equal(plan, a.plan)
    #end

    def test_useful_task_components
	t1, t2, t3, t4 = prepare_plan tasks: 4, model: Roby::Tasks::Simple
	t1.depends_on t2
	t2.signals(:start, t3, :stop)
	t2.planned_by t4

	plan.add_mission(t1)

	assert_equal([t1, t2, t4].to_set, plan.locally_useful_tasks)
	plan.add_mission(t3)
	assert_equal([t1, t2, t3, t4].to_set, plan.locally_useful_tasks)
	plan.unmark_mission(t1)
	assert_equal([t3].to_set, plan.locally_useful_tasks)
	assert_equal([t1, t2, t4].to_set, plan.unneeded_tasks)
    end

    def test_replace_task
	(p, c1), (c11, c12, c2, c3) = prepare_plan missions: 2, tasks: 4, model: Roby::Tasks::Simple
	p.depends_on c1, model: [Roby::Tasks::Simple, {}]
	c1.depends_on c11
	c1.depends_on c12
	p.depends_on c2
	c1.signals(:stop, c2, :start)
	c1.forward_to :start, c1, :stop
	c11.forward_to :success, c1, :success

	# Replace c1 by c3 and check that the hooks are properly called
	FlexMock.use do |mock|
	    p.singleton_class.class_eval do
		define_method('removed_child_object') do |child, relations|
		    mock.removed_hook(self, child, relations)
		end
	    end
	    c1.singleton_class.class_eval do
		define_method('removed_parent_object') do |parent, relations|
		    mock.removed_hook(self, parent, relations)
		end
	    end

	    mock.should_receive(:removed_hook).with(p, c1, [TaskStructure::Dependency]).once
	    mock.should_receive(:removed_hook).with(c1, p, [TaskStructure::Dependency]).once
	    mock.should_receive(:removed_hook).with(p, c2, [TaskStructure::Dependency])
	    mock.should_receive(:removed_hook).with(c2, p, [TaskStructure::Dependency])
	    mock.should_receive(:removed_hook).with(p, c3, [TaskStructure::Dependency])
	    mock.should_receive(:removed_hook).with(c3, p, [TaskStructure::Dependency])
	    plan.replace_task(c1, c3)
	end

	# Check that the external task and event structures have been
	# transferred. 
	assert( !p.child_object?(c1, TaskStructure::Dependency) )
	assert( p.child_object?(c3, TaskStructure::Dependency) )
	assert( c3.child_object?(c11, TaskStructure::Dependency) )
	assert( !c1.child_object?(c11, TaskStructure::Dependency) )

	assert( !c1.event(:stop).child_object?(c2.event(:start), EventStructure::Signal) )
	assert( c3.event(:stop).child_object?(c2.event(:start), EventStructure::Signal) )
	assert( c3.event(:success).parent_object?(c11.event(:success), EventStructure::Forwarding) )
	assert( !c1.event(:success).parent_object?(c11.event(:success), EventStructure::Forwarding) )
	# Also check that the internal event structure has *not* been transferred
	assert( !c3.event(:start).child_object?(c3.event(:stop), EventStructure::Forwarding) )
	assert( c1.event(:start).child_object?(c1.event(:stop), EventStructure::Forwarding) )

	# Check that +c1+ is no more marked as mission, and that c3 is marked. c1 should
	# still be in the plan
	assert(! plan.mission?(c1) )
	assert( plan.mission?(c3) )
	assert( plan.include?(c1) )

	# Check that #replace_task keeps the permanent flag too
	(root, p), t = prepare_plan permanent: 2, tasks: 1, model: Roby::Tasks::Simple
        root.depends_on p, model: Roby::Tasks::Simple

	plan.add_permanent(p)
	plan.replace_task(p, t)
	assert(!plan.permanent?(p))
	assert(plan.permanent?(t))
    end

    def test_replace
	(p, c1), (c11, c12, c2, c3) = prepare_plan missions: 2, tasks: 4, model: Roby::Tasks::Simple
	p.depends_on c1, model: Roby::Tasks::Simple
	c1.depends_on c11
	c1.depends_on c12
	p.depends_on c2
	c1.signals(:stop, c2, :start)
	c1.forward_to :start, c1, :stop
	c11.forward_to :success, c1, :success

	# Replace c1 by c3 and check that the hooks are properly called
	FlexMock.use do |mock|
	    p.singleton_class.class_eval do
		define_method('removed_child_object') do |child, relations|
		    mock.removed_hook(self, child, relations)
		end
	    end
	    c1.singleton_class.class_eval do
		define_method('removed_parent_object') do |parent, relations|
		    mock.removed_hook(self, parent, relations)
		end
	    end

	    mock.should_receive(:removed_hook).with(p, c1, [TaskStructure::Dependency]).once
	    mock.should_receive(:removed_hook).with(c1, p, [TaskStructure::Dependency]).once
	    mock.should_receive(:removed_hook).with(p, c2, [TaskStructure::Dependency])
	    mock.should_receive(:removed_hook).with(c2, p, [TaskStructure::Dependency])
	    mock.should_receive(:removed_hook).with(p, c3, [TaskStructure::Dependency])
	    mock.should_receive(:removed_hook).with(c3, p, [TaskStructure::Dependency])
	    plan.replace(c1, c3)
	end

	# Check that the external task and event structures have been
	# transferred. 
	assert( !p.child_object?(c1, TaskStructure::Dependency) )
	assert( p.child_object?(c3, TaskStructure::Dependency) )
	assert( c1.child_object?(c11, TaskStructure::Dependency) )
	assert( !c3.child_object?(c11, TaskStructure::Dependency) )

	assert( !c1.event(:stop).child_object?(c2.event(:start), EventStructure::Signal) )
	assert( c3.event(:stop).child_object?(c2.event(:start), EventStructure::Signal) )
	assert( c1.event(:success).parent_object?(c11.event(:success), EventStructure::Forwarding) )
	assert( !c3.event(:success).parent_object?(c11.event(:success), EventStructure::Forwarding) )
	# Also check that the internal event structure has *not* been transferred
	assert( !c3.event(:start).child_object?(c3.event(:stop), EventStructure::Forwarding) )
	assert( c1.event(:start).child_object?(c1.event(:stop), EventStructure::Forwarding) )

	# Check that +c1+ is no more marked as mission, and that c3 is marked. c1 should
	# still be in the plan
	assert(! plan.mission?(c1) )
	assert( plan.mission?(c3) )
	assert( plan.include?(c1) )
    end

    def test_replace_task_and_strong_relations
        t0, t1, t2, t3 = prepare_plan add: 4, model: Roby::Tasks::Simple

        t0.depends_on t1, model: Roby::Tasks::Simple
        t1.depends_on t2
        t1.stop_event.handle_with t2
        # The error handling relation is strong, so the t1 => t3 relation should
        # not be replaced at all
        plan.replace_task(t1, t3)

        assert !t1.depends_on?(t2)
        assert  t3.depends_on?(t2)
        assert  t1.child_object?(t2, TaskStructure::ErrorHandling)
        assert !t3.child_object?(t2, TaskStructure::ErrorHandling)
    end

    def test_replace_task_and_copy_relations_on_replace
        agent_t = Roby::Task.new_submodel do
            event :ready, controlable: true
        end

        t0, t1, t3 = prepare_plan add: 3, model: Roby::Tasks::Simple
        plan.add(t2 = agent_t.new)

        t0.depends_on t1, model: Roby::Tasks::Simple
        t1.executed_by t2

        # The error handling relation is marked as copy_on_replace, so the t1 =>
        # t2 relation should not be removed, but only copied
        plan.replace_task(t1, t3)

        assert t1.child_object?(t2, TaskStructure::ExecutionAgent)
        assert t3.child_object?(t2, TaskStructure::ExecutionAgent)
    end

    def test_replace_can_replace_a_task_with_unset_delayed_arguments
        task_m = Roby::Task.new_submodel do
            argument :arg
        end
        delayed_arg = flexmock(evaluate_delayed_argument: nil)
        plan.add(original = task_m.new(arg: delayed_arg))
        plan.add(replacing = task_m.new(arg: 10))
        plan.replace(original, replacing)
    end

    def test_free_events
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	plan.add_mission(t1)
	t1.depends_on t2
	assert_equal(plan, t2.plan)
	assert_equal(plan, t1.event(:start).plan)

	or_generator  = (t1.event(:stop) | t2.event(:stop))
	assert_equal(plan, or_generator.plan)
	assert(plan.free_events.include?(or_generator))
	or_generator.signals t3.event(:start)
	assert_equal(plan, t3.plan)

	and_generator = (t1.event(:stop) & t2.event(:stop))
	assert_equal(plan, and_generator.plan)
	assert(plan.free_events.include?(and_generator))
    end

    def test_plan_synchronization
	t1, t2 = prepare_plan tasks: 2
	plan.add_mission(t1)
	assert_equal(plan, t1.plan)
	assert_equal(nil, t2.plan)
	t1.depends_on t2
	assert_equal(plan, t1.plan)
	assert_equal(plan, t2.plan)
	assert(plan.include?(t2))

	e = EventGenerator.new(true)
	assert_equal(nil, e.plan)
	t1.signals(:start, e, :start)
	assert_equal(plan, e.plan)
	assert(plan.free_events.include?(e))

	# Now, make sure a PlanObject don't get included in the plan if add_child_object
	# raises
	adding_child_failure = Module.new do
	    def adding_child_object(child, relation, info)
		raise RuntimeError
	    end
	end
	model = Task.new_submodel do
	    include adding_child_failure
	end
	t1, t2 = model.new, model.new
	plan.add_mission(t1)
	assert_equal(plan, t1.plan)
	assert_equal(nil, t2.plan)
	assert_raises(RuntimeError) { t1.depends_on t2 }
	assert_equal(plan, t1.plan)
	assert_equal(plan, t2.plan)
	assert(plan.include?(t2))
    end

    # Checks that a garbage collected object (event or task) cannot be added back into the plan
    def test_garbage_collection_final
	t = Roby::Tasks::Simple.new
	e = EventGenerator.new(true)
	plan.real_plan.add [t, e]
	engine.garbage_collect
	assert_raises(ArgumentError) { plan.add(t) }
        assert !plan.known_tasks.include?(t)
	assert_raises(ArgumentError) { plan.add(e) }
        assert !plan.known_tasks.include?(e)
    end

    def test_proxy_operator
        t = Roby::Tasks::Simple.new
        assert_same t, plan[t, false]

        assert plan.include?(t)
        assert_same t, plan[t, true]

        plan.remove_object(t)
        assert_raises(ArgumentError) { plan[t] }
    end

    def test_task_finalized_called_on_clear
        plan.add(task = Roby::Task.new)
        flexmock(task).should_receive(:finalized!).once
        task.each_event do |ev|
            flexmock(ev).should_receive(:finalized!).once
        end
        plan.clear
    end

    def test_event_finalized_called_on_clear
        plan.add(ev = Roby::EventGenerator.new)
        flexmock(ev).should_receive(:finalized!).once
        plan.clear
    end

    def test_task_events_are_added_and_removed
        plan.add(task = Roby::Tasks::Simple.new)
        task.each_event do |ev|
            assert(plan.task_events.include?(ev))
        end
        plan.remove_object(task)
        task.each_event do |ev|
            assert(!plan.task_events.include?(ev))
        end
    end

    def test_task_events_are_removed_on_clear
        plan.add(task = Roby::Tasks::Simple.new)
        plan.clear
        task.each_event do |ev|
            assert(!plan.task_events.include?(ev))
        end
    end
end

class TC_Plan < Minitest::Test
    include TC_PlanStatic

    def test_transaction_stack
        assert_equal [plan], plan.transaction_stack
    end


    def test_quarantine
        t1, t2, t3, p = prepare_plan add: 4
        t1.depends_on t2
        t2.depends_on t3
        t2.planned_by p

        t1.signals :start, p, :start
        t2.signals :success, p, :start

        plan.add(t2)
        with_log_level(Roby, Logger::FATAL) do
            plan.quarantine(t2)
        end
        assert_equal([t2], plan.gc_quarantine.to_a)
        assert(t2.leaf?)
        assert(t2.success_event.leaf?)

        plan.remove_object(t2)
        assert(plan.gc_quarantine.empty?)
    end
    
    def test_failed_mission
        # The Plan object should emit a MissionFailed error if an exception
        # involves a mission ...
        Roby::ExecutionEngine.logger.level = Logger::FATAL

        t1, t2, t3, t4 = prepare_plan add: 4, model: Tasks::Simple
        t1.depends_on t2
        t2.depends_on t3
        t3.depends_on t4

        plan.add_mission(t2)
        t1.start!
        t2.start!
        t3.start!
        t4.start!
        error = assert_raises(SynchronousEventProcessingMultipleErrors) { t4.stop! }
        errors = error.errors
        assert_equal 2, errors.size
        child_failed   = errors.find { |e, _| e.exception.kind_of?(ChildFailedError) }
        mission_failed = errors.find { |e, _| e.exception.kind_of?(MissionFailedError) }

        assert child_failed
        assert_equal t4, child_failed.first.origin
        assert mission_failed
        assert_equal t2, mission_failed.first.origin
    end

    def test_plan_discovery_when_adding_child_task
        root, t1, t2 = (1..3).map { Roby::Task.new }
        assert !root.plan
        assert !t1.plan

        root.depends_on t1, role: 'bla'
        plan.add(t1)

        assert_equal plan, root.plan
        assert_equal plan, t1.plan
    end

    def test_discover_new_objects_single_object
        t = Roby::Task.new
        new = plan.discover_new_objects(TaskStructure.relations, nil, (set = Set.new), [t].to_set)
        assert_equal [t], new.to_a
        assert_equal [t], set.to_a
    end

    def test_discover_new_objects_with_child
        t = Roby::Task.new
        child = Roby::Task.new
        t.depends_on child
        new = plan.discover_new_objects(TaskStructure.relations, nil, (set = Set.new), [t].to_set)
        assert_equal [t, child].to_set, new
        assert_equal [t, child].to_set, set
        plan.add([t, child])
    end

    def test_discover_new_objects_with_recursive
        t = Roby::Task.new
        child = Roby::Task.new
        t.depends_on child
        next_task = Roby::Task.new
        child.planned_by next_task

        new = plan.discover_new_objects(TaskStructure.relations, nil, (set = Set.new), [t].to_set)
        assert_equal [t, child, next_task].to_set, new
        assert_equal [t, child, next_task].to_set, set
        plan.add([t, child, next_task])
    end

    def test_discover_new_objects_does_no_account_for_already_discovered_objects
        t = Roby::Task.new
        child = Roby::Task.new
        t.depends_on child
        next_task = Roby::Task.new
        child.planned_by next_task

        new = plan.discover_new_objects(TaskStructure.relations, nil, (set = [child].to_set), [t].to_set)
        assert_equal [t].to_set, new
        assert_equal [t, child].to_set, set
        plan.add([t, child, next_task])
    end
end

describe Roby::Plan do
    describe "#add_trigger" do
        it "yields new tasks that match the given object" do
            match = flexmock
            match.should_receive(:===).with(task = Roby::Task.new).and_return(true)
            recorder = flexmock
            recorder.should_receive(:called).once.with(task)
            plan.add_trigger match do |task|
                recorder.called(task)
            end
            plan.add task
        end
        it "does not yield new tasks that do not match the given object" do
            match = flexmock
            match.should_receive(:===).with(task = Roby::Task.new).and_return(false)
            recorder = flexmock
            recorder.should_receive(:called).never
            plan.add_trigger match do |task|
                recorder.called(task)
            end
            plan.add task
        end
        it "yields matching tasks that already are in the plan" do
            match = flexmock
            match.should_receive(:===).with(task = Roby::Task.new).and_return(true)
            recorder = flexmock
            recorder.should_receive(:called).once
            plan.add task
            plan.add_trigger match do |task|
                recorder.called(task)
            end
        end
        it "does not yield not matching tasks that already are in the plan" do
            match = flexmock
            match.should_receive(:===).with(task = Roby::Task.new).and_return(false)
            recorder = flexmock
            recorder.should_receive(:called).never
            plan.add task
            plan.add_trigger match do |task|
                recorder.called(task)
            end
        end
    end

    describe "#remove_trigger" do
        it "allows to remove a trigger added by #add_trigger" do
            match = flexmock
            trigger = plan.add_trigger match do |task|
            end
            plan.remove_trigger trigger
            match.should_receive(:===).never
            plan.add Roby::Task.new
        end
    end

    describe "#add_task_set" do
        it "registers the task events in #task_events" do
            plan.add_task_set([task = Roby::Task.new])
            assert(plan.task_events.to_set.subset?(task.bound_events.values.to_set))
        end
    end

    describe "#unneeded_events" do
        it "returns free events that are connected to nothing" do
            plan.add(ev = Roby::EventGenerator.new)
            assert_equal [ev].to_set, plan.unneeded_events.to_set
        end
        it "does not return free events that are reachable from a permanent event" do
            plan.add_permanent(ev = Roby::EventGenerator.new)
            assert plan.unneeded_events.empty?
        end
        it "does not return free events that are reachable from a task event" do
            plan.add(t = Roby::Task.new)
            ev = Roby::EventGenerator.new
            t.start_event.forward_to ev
            assert plan.unneeded_events.empty?
        end
        it "does not return free events that can reach a task event" do
            plan.add(t = Roby::Task.new)
            ev = Roby::EventGenerator.new
            ev.forward_to t.start_event
            assert plan.unneeded_events.empty?
        end
    end
end

