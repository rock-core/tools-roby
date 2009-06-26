$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'

require 'flexmock'


module TC_PlanStatic
    include Roby
    include Roby::Test

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
    end
    def test_add_task_deprecated_discover
        t = Task.new
	deprecated_feature { plan.discover(t) }
        assert_task_state(t, :normal)
    end
    def test_remove_task
	plan.remove_object(t)
        assert_task_state(t, :removed)
    end

    def test_add_mission
	plan.add_mission(t = Task.new)
        assert_task_state(t, :mission)
    end
    def test_add_mission_deprecated_insert
	plan.insert(t = Task.new)
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

    def test_add_mission_deprecated_insert
        t = Task.new
        deprecated_feature { plan.insert(t) }
        assert_task_state(t, :mission)
    end
    def test_unmark_mission_deprecated_discard
	plan.add_mission(t = Task.new)
	deprecated_feature { plan.discard(t) }
        assert_task_state(t, :normal)
    end
    def test_unmark_mission_deprecated_remove_mission
	plan.add_mission(t = Task.new)
	deprecated_feature { plan.remove_mission(t) }
        assert_task_state(t, :normal)
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

    def test_add_permanent_deprecated_permanent
        t = Task.new
	deprecated_feature { plan.permanent(t) }
        assert_task_state(t, :permanent)
    end
    def test_unmark_permanent_deprecated_auto
	plan.add_permanent(t = Task.new)
	deprecated_feature { plan.auto(t) }
        assert_task_state(t, :normal)
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
    def test_permanent_event_deprecated_permanent
        ev = EventGenerator.new
	deprecated_feature { plan.permanent(ev) }
        assert_planobject_state(ev, :permanent)
    end
    def test_unmark_permanent_event_deprecated_auto
	plan.add_permanent(ev = EventGenerator.new)
	deprecated_feature { plan.unmark_permanent(ev) }
        assert_planobject_state(ev, :normal)
    end

    # TODO: test that #remove_object removes the object from its relations
    # TODO: test that #add adds related objects

    #def test_discover
    #    t1, t2, t3, t4 = prepare_plan :tasks => 4, :model => Roby::Test::SimpleTask
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
	t1, t2, t3, t4 = prepare_plan :tasks => 4, :model => Roby::Test::SimpleTask
	t1.depends_on t2
	t2.signals(:start, t3, :stop)
	t2.planned_by t4

	plan.add_mission(t1)

	assert_equal([t1, t2, t4].to_value_set, plan.locally_useful_tasks)
	plan.add_mission(t3)
	assert_equal([t1, t2, t3, t4].to_value_set, plan.locally_useful_tasks)
	plan.unmark_mission(t1)
	assert_equal([t3].to_value_set, plan.locally_useful_tasks)
	assert_equal([t1, t2, t4].to_value_set, plan.unneeded_tasks)
    end

    def test_replace_task
	(p, c1), (c11, c12, c2, c3) = prepare_plan :missions => 2, :tasks => 4, :model => Roby::Test::SimpleTask
	p.depends_on c1
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
		    mock.removed_hook(p, child, relations)
		end
	    end
	    c1.singleton_class.class_eval do
		define_method('removed_parent_object') do |parent, relations|
		    mock.removed_hook(c1, parent, relations)
		end
	    end

	    mock.should_receive(:removed_hook).with(p, c1, [TaskStructure::Hierarchy]).once
	    mock.should_receive(:removed_hook).with(c1, p, [TaskStructure::Hierarchy]).once
	    assert_nothing_raised { plan.replace_task(c1, c3) }
	end

	# Check that the external task and event structures have been
	# transferred. 
	assert( !p.child_object?(c1, TaskStructure::Hierarchy) )
	assert( p.child_object?(c3, TaskStructure::Hierarchy) )
	assert( c3.child_object?(c11, TaskStructure::Hierarchy) )
	assert( !c1.child_object?(c11, TaskStructure::Hierarchy) )

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
	p, t = prepare_plan :permanent => 1, :tasks => 1, :model => Roby::Test::SimpleTask
	plan.add_permanent(p)
	plan.replace_task(p, t)
	assert(!plan.permanent?(p))
	assert(plan.permanent?(t))
    end

    def test_replace
	(p, c1), (c11, c12, c2, c3) = prepare_plan :missions => 2, :tasks => 4, :model => Roby::Test::SimpleTask
	p.depends_on c1
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
		    mock.removed_hook(p, child, relations)
		end
	    end
	    c1.singleton_class.class_eval do
		define_method('removed_parent_object') do |parent, relations|
		    mock.removed_hook(c1, parent, relations)
		end
	    end

	    mock.should_receive(:removed_hook).with(p, c1, [TaskStructure::Hierarchy]).once
	    mock.should_receive(:removed_hook).with(c1, p, [TaskStructure::Hierarchy]).once
	    assert_nothing_raised { plan.replace(c1, c3) }
	end

	# Check that the external task and event structures have been
	# transferred. 
	assert( !p.child_object?(c1, TaskStructure::Hierarchy) )
	assert( p.child_object?(c3, TaskStructure::Hierarchy) )
	assert( c1.child_object?(c11, TaskStructure::Hierarchy) )
	assert( !c3.child_object?(c11, TaskStructure::Hierarchy) )

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

    def test_remove_task
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	t1.depends_on t2
	t1.signals(:stop, t3, :start)

	plan.add_mission(t1)
	plan.add_mission(t3)

	assert(!t1.leaf?)
	plan.remove_object(t2)
	assert(t1.leaf?)
	assert(!plan.include?(t2))

	assert(!t1.event(:stop).leaf?(EventStructure::Signal))
	plan.remove_object(t3)
	assert(t1.event(:stop).leaf?(EventStructure::Signal))
	assert(!plan.include?(t3))
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
	t1, t2 = prepare_plan :tasks => 2
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
	model = Class.new(Task) do
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
	t = SimpleTask.new
	e = EventGenerator.new(true)
	plan.real_plan.add [t, e]
	engine.garbage_collect
	assert_raises(ArgumentError) { plan.add(t) }
	assert_raises(ArgumentError) { plan.add(e) }
    end
end

class TC_Plan < Test::Unit::TestCase
    include TC_PlanStatic
end

