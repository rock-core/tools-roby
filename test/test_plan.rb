$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/log'
require 'roby/state/information'
require 'test/mockups/tasks'

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
	assert(t1.event(:start).child_objects(EventStructure::Signal).empty?)
	assert(!e.plan)
	assert_raises(ArgumentError) { e.plan = plan }

	plan.remove_object(t2)
	assert(!plan.include?(e))
	assert(!t1.realized_by?(t2))
	assert(!t2.plan)
	assert_raises(ArgumentError) { t2.plan = plan }
    end

    def test_base
	task_model = Class.new(Task) do 
	    event :stop, :command => true
	end

	t1, t2, t3, t4 = 4.enum_for(:times).map { task_model.new }
	t1.realized_by t2
	t2.on(:start, t3, :stop)
	t2.planned_by t4

	result = plan.insert(t1)
	assert_equal(plan, result)
	assert( plan.include?(t1) )
	assert( plan.include?(t2) )
	assert( !plan.include?(t3) ) # t3 not related because of hierarchy
	assert( plan.include?(t4) )

	assert( plan.mission?(t1) )
	assert( !plan.mission?(t2) )

	assert_equal([t1, t2, t4].to_value_set, plan.useful_tasks)
	plan.insert(t3)
	assert_equal([t1, t2, t3, t4].to_value_set, plan.useful_tasks)
	plan.discard(t1)
	assert_equal([t3].to_value_set, plan.useful_tasks)
	assert_equal([t1, t2, t4].to_value_set, plan.unneeded_tasks)
    end

    def test_replace
	klass = Class.new(Task) do
	    event(:start, :command => true)
	    event(:stop)
	    forward :start => :stop
	end

	p, c1, c2, c3 = (1..4).map { klass.new }
	p.realized_by c1
	p.realized_by c2
	c1.on(:stop, c2, :start)

	plan.insert(p)
	plan.insert(c1)
	FlexMock.use do |mock|
	    p.singleton_class.class_eval do
		define_method('removed_child_object') do |child, type|
		    mock.removed_hook(p, child, type)
		end
	    end
	    c1.singleton_class.class_eval do
		define_method('removed_parent_object') do |parent, type|
		    mock.removed_hook(c1, parent, type)
		end
	    end

	    mock.should_receive(:removed_hook).with(p, c1, TaskStructure::Hierarchy)
	    mock.should_receive(:removed_hook).with(c1, p, TaskStructure::Hierarchy)
	    assert_nothing_raised { plan.replace(c1, c3) }
	end

	assert(! plan.mission?(c1) )
	assert( plan.include?(c1) )
	plan.garbage_collect
	assert(! plan.include?(c1) )

	assert( p.child_object?(c3, TaskStructure::Hierarchy) )
	assert( !p.child_object?(c1, TaskStructure::Hierarchy) )
	assert( c3.event(:stop).child_object?(c2.event(:start), EventStructure::Signal) )
    end

    def test_remove_task
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	t1.realized_by t2
	t1.on(:stop, t3, :start)

	plan.insert(t1)
	plan.insert(t3)

	assert(!t1.children.empty?)
	plan.remove_task(t2)
	assert(t1.children.empty?)
	assert(!plan.include?(t2))

	assert(!t1.event(:stop).child_objects(EventStructure::Signal).empty?)
	plan.remove_task(t3)
	assert(t1.event(:stop).child_objects(EventStructure::Signal).empty?)
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
	assert_equal(nil, t2.plan)
	assert(!plan.include?(t2))
    end
end

class TC_Plan < Test::Unit::TestCase
    include TC_PlanStatic
    include Roby::Test

    def clear_finalized; @finalized_tasks_recorder.clear end
    def finalized_tasks; @finalized_tasks_recorder.tasks end
    def finalized_events; @finalized_tasks_recorder.events end
    class FinalizedTaskRecorder
	attribute(:tasks) { Array.new }
	attribute(:events) { Array.new }
	def finalized_task(time, plan, task)
	    tasks << task
	end
	def finalized_event(time, plan, event)
	    events << event if event.root_object?
	end
	def clear
	    tasks.clear
	    events.clear
	end
	def splat?; true end
    end

    def setup
	super
	Roby::Log.loggers << (@finalized_tasks_recorder = FinalizedTaskRecorder.new)
    end
    def teardown
	Roby::Log.loggers.delete(@finalized_tasks_recorder)
	super
    end

    def assert_finalizes(plan, unneeded, finalized = nil)
	finalized ||= unneeded
	clear_finalized

	yield if block_given?

	assert_equal(unneeded.to_set, plan.unneeded_tasks.to_set)
	plan.garbage_collect
	assert_equal(finalized.to_set, (finalized_tasks.to_set | finalized_events.to_set))
	assert(! finalized.any? { |t| plan.include?(t) })
    end

    def test_garbage_collect_tasks
	klass = Class.new(Task) do
	    attr_accessor :delays

	    event(:start, :command => true)
	    def stop(context)
		if delays
		    return
		else
		    emit(:stop)
		end
	    end
	    event(:stop)
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
	    t5.event(:stop).emit(nil)
	end
    end
    
    def test_force_garbage_collect_tasks
	t1 = Class.new(Task) do
	    def stop(context); end
	    event :stop
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

    def test_garbage_collect_events
	t  = SimpleTask.new
	e1 = EventGenerator.new(true)

	plan.insert(t)
	plan.discover(e1)
	assert(!Distributed.remotely_useful?(e1))
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
end

