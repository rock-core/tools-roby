require 'test_config'
require 'flexmock'

require 'roby/plan'
require 'roby/state/information'

module TC_PlanStatic
    attr_reader :plan
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
	assert(!plan.permanent?(t1))

	plan.discard(t1)
	assert(plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(!plan.permanent?(t1))

	plan.remove_task(t1)
	plan.discover(t1 = Task.new)
	assert(plan.include?(t1))
	assert(!plan.mission?(t1))
	plan.insert(t1)
	assert(plan.mission?(t1))

	plan.remove_task(t1)
	plan.permanent(t1 = Task.new)
	assert(plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(plan.permanent?(t1))
	plan.auto(t1)
	assert(plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(!plan.permanent?(t1))

	plan.permanent(t1)
	plan.remove_task(t1)
	assert(!plan.include?(t1))
	assert(!plan.mission?(t1))
	assert(!plan.permanent?(t1))
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
	    on :start => :stop
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
end

class TC_Plan < Test::Unit::TestCase
    include TC_PlanStatic
    include RobyTestCommon

    def setup
	@plan = Plan.new
	super
    end

    def assert_finalizes(plan, unneeded, finalized = nil)
	finalized ||= unneeded
	plan.finalized_tasks = []

	yield if block_given?

	assert_equal(unneeded.to_set, plan.unneeded_tasks.to_set)
	plan.garbage_collect
	assert_equal(finalized.to_set, plan.finalized_tasks.to_set)
	assert(! finalized.any? { |t| plan.include?(t) })
    end

    def test_garbage_collect
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

	class << plan
	    attribute(:finalized_tasks) { Array.new }
	    def finalized(task)
		finalized_tasks << task
	    end
	end

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
    
    def test_force_garbage_collect
	t1 = Class.new(Task) do
	    def stop(context); end
	    event :stop
	end.new
	t2 = Task.new
	t1.realized_by t2

	class << plan
	    attribute(:finalized_tasks) { Array.new }
	    def finalized(task)
		finalized_tasks << task
	    end
	end

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
end

