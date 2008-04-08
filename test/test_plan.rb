$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/log'
require 'roby/state/information'
require 'roby/test/tasks/simple_task'

require 'flexmock'


module TC_PlanStatic
    include Roby

    def test_add_remove
	t1 = Task.new

	plan.discover(t1)
	assert(plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(!plan.permanent?(t1))

	plan.remove_task(t1)
	assert(!plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(!plan.permanent?(t1))

	plan.insert(t1 = Task.new)
	assert(plan.include?(t1))
	assert(plan.mission?(t1))
	assert(t1.mission?)
	assert(!plan.permanent?(t1))

	plan.discard(t1)
	assert(plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(!t1.mission?)
	assert(!plan.permanent?(t1))
	plan.remove_task(t1)

	plan.discover(t1 = Task.new)
	assert(plan.include?(t1))
	assert(!plan.mission?(t1))
	plan.insert(t1)
	assert(plan.mission?(t1))
	assert(t1.mission?)
	plan.remove_task(t1)

	plan.permanent(t1 = Task.new)
	assert(plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(!t1.mission?)
	assert(plan.permanent?(t1))
	plan.auto(t1)
	assert(plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(!t1.mission?)
	assert(!plan.permanent?(t1))

	plan.permanent(t1)
	plan.remove_task(t1)
	assert(!plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(!t1.mission?)
	assert(!plan.permanent?(t1))
    end

    def test_plan_remove_object
	t1, t2 = prepare_plan :tasks => 2
	plan.discover(e = EventGenerator.new(true))

	t1.realized_by(t2)
	t1.on(:start, e)

	plan.remove_object(e)
	assert(!plan.free_events.include?(e))
	assert(t1.event(:start).leaf?(EventStructure::Signal))
	assert(!e.plan)
	assert_raises(ArgumentError) { e.plan = plan }

	plan.remove_object(t2)
	assert(!plan.include?(e))
	assert(!t1.realized_by?(t2))
	assert(!t2.plan)
	assert_raises(ArgumentError) { t2.plan = plan }
    end

    def test_discover
	t1, t2, t3, t4 = prepare_plan :tasks => 4, :model => Roby::Test::SimpleTask
	t1.realized_by t2
	or_ev = OrGenerator.new
	t2.event(:start).on or_ev
	or_ev.on t3.event(:stop)
	t2.planned_by t4

	result = plan.discover(t1)
	assert_equal(plan, result)
	assert( plan.include?(t1) )
	assert( plan.include?(t2) )
	assert( plan.free_events.include?(or_ev))
	assert( !plan.include?(t3) ) # t3 not related because of task structure
	assert( plan.include?(t4) )

	# Discover t3 to help plan cleanup
	plan.discover(t3)

	# Discover an AndGenerator and not its sources. The sources
	# must be discovered automatically
	a, b = (1..2).map { EventGenerator.new(true) }
	and_event = a & b
	plan.discover(and_event)
	assert_equal(plan, a.plan)
    end

    def test_insert
	t1, t2, t3, t4 = prepare_plan :tasks => 4, :model => Roby::Test::SimpleTask
	t1.realized_by t2
	t2.on(:start, t3, :stop)
	t2.planned_by t4

	result = plan.insert(t1)
	assert_equal(plan, result)
	assert( plan.include?(t1) )
	assert( plan.include?(t2) )
	assert( !plan.include?(t3) ) # t3 not related because of task structure
	assert( plan.include?(t4) )

	assert( plan.mission?(t1) )
	assert( !plan.mission?(t2) )

	# Discover t3 to help plan cleanup
	plan.discover(t3)
    end

    def test_useful_task_components
	t1, t2, t3, t4 = prepare_plan :tasks => 4, :model => Roby::Test::SimpleTask
	t1.realized_by t2
	t2.on(:start, t3, :stop)
	t2.planned_by t4

	plan.insert(t1)

	assert_equal([t1, t2, t4].to_value_set, plan.locally_useful_tasks)
	plan.insert(t3)
	assert_equal([t1, t2, t3, t4].to_value_set, plan.locally_useful_tasks)
	plan.discard(t1)
	assert_equal([t3].to_value_set, plan.locally_useful_tasks)
	assert_equal([t1, t2, t4].to_value_set, plan.unneeded_tasks)
    end

    def test_replace_task
	(p, c1), (c11, c12, c2, c3) = prepare_plan :missions => 2, :tasks => 4, :model => Roby::Test::SimpleTask
	p.realized_by c1
	c1.realized_by c11
	c1.realized_by c12
	p.realized_by c2
	c1.on(:stop, c2, :start)
	c1.forward :start, c1, :stop
	c11.forward :success, c1

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
	plan.permanent(p)
	plan.replace_task(p, t)
	assert(!plan.permanent?(p))
	assert(plan.permanent?(t))
    end

    def test_replace
	(p, c1), (c11, c12, c2, c3) = prepare_plan :missions => 2, :tasks => 4, :model => Roby::Test::SimpleTask
	p.realized_by c1
	c1.realized_by c11
	c1.realized_by c12
	p.realized_by c2
	c1.on(:stop, c2, :start)
	c1.forward :start, c1, :stop
	c11.forward :success, c1

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
	t1.realized_by t2
	t1.on(:stop, t3, :start)

	plan.insert(t1)
	plan.insert(t3)

	assert(!t1.leaf?)
	plan.remove_task(t2)
	assert(t1.leaf?)
	assert(!plan.include?(t2))

	assert(!t1.event(:stop).leaf?(EventStructure::Signal))
	plan.remove_task(t3)
	assert(t1.event(:stop).leaf?(EventStructure::Signal))
	assert(!plan.include?(t3))
    end

    def test_free_events
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	plan.insert(t1)
	t1.realized_by t2
	assert_equal(plan, t2.plan)
	assert_equal(plan, t1.event(:start).plan)

	or_generator  = (t1.event(:stop) | t2.event(:stop))
	assert_equal(plan, or_generator.plan)
	assert(plan.free_events.include?(or_generator))
	or_generator.on t3.event(:start)
	assert_equal(plan, t3.plan)

	and_generator = (t1.event(:stop) & t2.event(:stop))
	assert_equal(plan, and_generator.plan)
	assert(plan.free_events.include?(and_generator))
    end

    def test_plan_synchronization
	t1, t2 = prepare_plan :tasks => 2
	plan.insert(t1)
	assert_equal(plan, t1.plan)
	assert_equal(nil, t2.plan)
	t1.realized_by t2
	assert_equal(plan, t1.plan)
	assert_equal(plan, t2.plan)
	assert(plan.include?(t2))

	e = EventGenerator.new(true)
	assert_equal(nil, e.plan)
	t1.on(:start, e)
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
	plan.insert(t1)
	assert_equal(plan, t1.plan)
	assert_equal(nil, t2.plan)
	assert_raises(RuntimeError) { t1.realized_by t2 }
	assert_equal(plan, t1.plan)
	assert_equal(plan, t2.plan)
	assert(plan.include?(t2))
    end
end

class TC_Plan < Test::Unit::TestCase
    include TC_PlanStatic
    include Roby::Test

    def clear_finalized
        Roby::Log.flush
        @finalized_tasks_recorder.clear
    end
    def finalized_tasks; @finalized_tasks_recorder.tasks end
    def finalized_events; @finalized_tasks_recorder.events end
    class FinalizedTaskRecorder
	attribute(:tasks) { Array.new }
	attribute(:events) { Array.new }
	def finalized_task(time, plan, task)
	    tasks << task
	end
	def finalized_event(time, plan, event)
	    events << event unless event.respond_to?(:task)
	end
	def clear
	    tasks.clear
	    events.clear
	end
	def splat?; true end
    end

    def setup
	super
	Roby::Log.add_logger(@finalized_tasks_recorder = FinalizedTaskRecorder.new)
    end
    def teardown
	Roby::Log.remove_logger @finalized_tasks_recorder
	super
    end

    def assert_finalizes(plan, unneeded, finalized = nil)
	finalized ||= unneeded
	finalized = finalized.map { |obj| obj.remote_id }
	clear_finalized

	yield if block_given?

	assert_equal(unneeded.to_set, plan.unneeded_tasks.to_set)
	plan.garbage_collect
        process_events
	plan.garbage_collect

        # !!! We are actually relying on the logging queue for this to work.
        # make sure it is empty before testing anything
        Roby::Log.flush

	assert_equal(finalized.to_set, (finalized_tasks.to_set | finalized_events.to_set))
	assert(! finalized.any? { |t| plan.include?(t) })
    end

    def test_garbage_collect_tasks
	klass = Class.new(Task) do
	    attr_accessor :delays

	    event(:start, :command => true)
	    event(:stop) do |context|
                if !delays
                    emit(:stop)
                end
            end
	end

	t1, t2, t3, t4, t5, t6, t7, t8, p1 = (1..9).map { |i| klass.new(:id => i) }
	t1.realized_by t3
	t2.realized_by t3
	t3.realized_by t4
	t5.realized_by t4
	t5.planned_by p1
	p1.realized_by t6

	t7.realized_by t8

	[t1, t2, t5].each { |t| plan.insert(t) }
	plan.permanent(t7)

	assert_finalizes(plan, [])
	assert_finalizes(plan, [t1]) { plan.discard(t1) }
	assert_finalizes(plan, [t2, t3]) do
	    t2.start!(nil)
	    plan.discard(t2)
	end
	assert_finalizes(plan, [t5, t4, p1, t6], []) do
	    t5.delays = true
	    t5.start!(nil)
	    plan.discard(t5)
	end
	assert(t5.event(:stop).pending?)
	assert_finalizes(plan, [t5, t4, p1, t6]) do
	    t5.emit(:stop)
	end
    end
    
    def test_force_garbage_collect_tasks
	t1 = Class.new(Task) do
	    event(:stop) { |context| }
	end.new
	t2 = Task.new
	t1.realized_by t2

	plan.insert(t1)
	t1.start!
	assert_finalizes(plan, []) do
	    plan.garbage_collect([t1])
	end
	assert(t1.event(:stop).pending?)

	assert_finalizes(plan, [t1, t2], [t1, t2]) do
	    # This stops the mission, which will be automatically discarded
	    t1.event(:stop).emit(nil)
	end
    end

    def test_gc_ignores_incoming_events
	Roby::Plan.logger.level = Logger::WARN
	a, b = prepare_plan :discover => 2, :model => SimpleTask
	a.on(:stop, b, :start)
	a.start!

	process_events
	process_events
	assert(!a.plan)
	assert(!b.plan)
	assert(!b.event(:start).happened?)
    end

    # Test a setup where there is both pending tasks and running tasks. This
    # checks that #stop! is called on all the involved tasks. This tracks
    # problems related to bindings in the implementation of #garbage_collect:
    # the killed task bound to the Control.once block must remain the same.
    def test_gc_stopping
	Roby::Plan.logger.level = Logger::WARN
	running_task = nil
	FlexMock.use do |mock|
	    task_model = Class.new(Task) do
		event :start, :command => true
		event :stop do |ev|
		    mock.stop(self)
		end
	    end

	    running_tasks = (1..5).map do
		task_model.new
	    end

	    plan.discover(running_tasks)
	    t1, t2 = Roby::Task.new, Roby::Task.new
	    t1.realized_by t2
	    plan.discover(t1)

	    running_tasks.each do |t|
		t.start!
		mock.should_receive(:stop).with(t).once
	    end
		
	    plan.garbage_collect
	    process_events

	    assert(!plan.include?(t1))
	    assert(!plan.include?(t2))
	    running_tasks.each do |t|
		assert(t.finishing?)
		t.emit(:stop)
	    end

	    plan.garbage_collect
	    running_tasks.each do |t|
		assert(!plan.include?(t))
	    end
	end

    ensure
	running_task.emit(:stop) if running_task && !running_task.finished?
    end

    def test_garbage_collect_events
	t  = SimpleTask.new
	e1 = EventGenerator.new(true)

	plan.insert(t)
	plan.discover(e1)
	assert_equal([e1], plan.unneeded_events.to_a)
	t.event(:start).on e1
	assert_equal([], plan.unneeded_events.to_a)

	e2 = EventGenerator.new(true)
	plan.discover(e2)
	assert_equal([e2], plan.unneeded_events.to_a)
	e1.forward e2
	assert_equal([], plan.unneeded_events.to_a)

	plan.remove_object(t)
	assert_equal([e1, e2].to_value_set, plan.unneeded_events)
    end

    # Checks that a garbage collected object (event or task) cannot be added back into the plan
    def test_garbage_collection_final
	t = SimpleTask.new
	e = EventGenerator.new(true)
	plan.discover [t, e]
	plan.garbage_collect
	assert_raises(ArgumentError) { plan.discover(t) }
	assert_raises(ArgumentError) { plan.discover(e) }
    end

    def test_garbage_collect_weak
	Roby.control.run :detach => true

	Roby.execute do
	    planning, planned, influencing = prepare_plan :discover => 3, :model => SimpleTask

	    planned.planned_by planning
	    influencing.realized_by planned
	    planning.influenced_by influencing

	    planned.start!
	    planning.start!
	    influencing.start!
	end

	Roby.wait_one_cycle
	Roby.wait_one_cycle
	Roby.wait_one_cycle

	assert(plan.known_tasks.empty?)
    end

    def test_mission_failed
	model = Class.new(SimpleTask) do
	    event :specialized_failure, :command => true
	    forward :specialized_failure => :failed
	end

	task = prepare_plan :missions => 1, :model => model
	task.start!
	task.specialized_failure!
	
	error = Roby.check_failed_missions(plan).first.exception
	assert_kind_of(Roby::MissionFailedError, error)
	assert_equal(task.event(:specialized_failure).last, error.failure_point)

	# Makes teardown happy
	plan.remove_object(task)
    end
end

