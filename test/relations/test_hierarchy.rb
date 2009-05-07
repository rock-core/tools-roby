$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'

class TC_RealizedBy < Test::Unit::TestCase
    include Roby::Test

    def test_check_structure_registration
        assert plan.structure_checks.include?(Hierarchy.method(:check_structure))
    end

    def test_definition
	tag   = TaskModelTag.new
	klass = Class.new(SimpleTask) do
	    argument :id
	    include tag
	end
	plan.discover(t1 = SimpleTask.new)

	# Check validation of the model
	child = nil
	assert_nothing_raised { t1.realized_by((child = klass.new), :model => SimpleTask) }
	assert_equal([SimpleTask, {}], t1[child, Hierarchy][:model])

	assert_nothing_raised { t1.realized_by klass.new, :model => [Roby::Task, {}] }
	assert_nothing_raised { t1.realized_by klass.new, :model => tag }

	plan.discover(simple_task = SimpleTask.new)
	assert_raises(ArgumentError) { t1.realized_by simple_task, :model => [Class.new(Roby::Task), {}] }
	assert_raises(ArgumentError) { t1.realized_by simple_task, :model => TaskModelTag.new }
	
	# Check validation of the arguments
	plan.discover(model_task = klass.new)
	assert_raises(ArgumentError) { t1.realized_by model_task, :model => [SimpleTask, {:id => 'bad'}] }

	plan.discover(child = klass.new(:id => 'good'))
	assert_raises(ArgumentError) { t1.realized_by child, :model => [klass, {:id => 'bad'}] }
	assert_nothing_raised { t1.realized_by child, :model => [klass, {:id => 'good'}] }
	assert_equal([klass, { :id => 'good' }], t1[child, TaskStructure::Hierarchy][:model])

	# Check edge annotation
	t2 = SimpleTask.new
	t1.realized_by t2, :model => SimpleTask
	assert_equal([SimpleTask, {}], t1[t2, TaskStructure::Hierarchy][:model])
	t2 = klass.new(:id => 10)
	t1.realized_by t2, :model => [klass, { :id => 10 }]
    end

    Hierarchy = TaskStructure::Hierarchy

    def test_exception_printing
        parent, child = prepare_plan :discover => 2, :model => SimpleTask
        parent.realized_by child
        parent.start!
        child.start!
        child.failed!

	error = plan.check_structure.find { true }[0].exception
	assert_kind_of(ChildFailedError, error)
        assert_nothing_raised do
            Roby.format_exception(error)
        end

        parent.stop!
    end

    def create_pair(options)
	child_model = Class.new(SimpleTask) do
	    event :first, :command => true
	    event :second, :command => true
	end

	p1 = SimpleTask.new
	child = child_model.new
	plan.discover([p1, child])
	p1.realized_by child, options
	plan.add_mission(p1)

	child.start!; p1.start!
        return p1, child
    end

    def assert_child_failed(child, reason, plan)
	result = plan.check_structure
	assert_equal([child].to_set, result.map { |e, _| e.exception.failed_task }.to_set)
	assert_equal([reason].to_set, result.map { |e, _| e.exception.failure_point }.to_set)
    end


    def test_success
        parent, child = create_pair :success => [:first], 
            :failure => [:stop],
            :remove_when_done => false

	assert_equal({}, plan.check_structure)
	child.first!
	assert_equal({}, plan.check_structure)
        assert(parent.realized_by?(child))
    end

    def test_success_removal
        parent, child = create_pair :success => [:first], 
            :failure => [:stop],
            :remove_when_done => true

	child.first!
	assert_equal({}, plan.check_structure)
        assert(!parent.realized_by?(child))
    end

    def test_success_preempts_explicit_failed
        parent, child = create_pair :success => [:first], 
            :failure => [:stop]

	child.first!
        child.stop!
	assert_equal({}, plan.check_structure)
    end

    def test_success_preempts_failure_on_unreachable
        parent, child = create_pair :success => [:first]

	child.first!
        child.stop!
	assert_equal({}, plan.check_structure)
    end

    def test_failure_explicit
        parent, child = create_pair :success => [:first], 
            :failure => [:stop]

        child.stop!
	assert_child_failed(child, child.event(:stop).last, plan)
        plan.clear
    end

    def test_failure_on_unreachable
        parent, child = create_pair :success => [:first]

        child.stop!
	assert_child_failed(child, child.event(:first), plan)
        plan.clear
    end

    def test_fullfilled_model
	tag = TaskModelTag.new
	klass = Class.new(SimpleTask) do
	    include tag
	end

	p1, p2, child = prepare_plan :discover => 3, :model => klass

	p1.realized_by child, :model => SimpleTask
	p2.realized_by child, :model => Roby::Task
	assert_equal([[SimpleTask], {}], child.fullfilled_model)
	p1.remove_child(child)
	assert_equal([[Roby::Task], {}], child.fullfilled_model)
	p1.realized_by child, :model => tag
	assert_equal([[Roby::Task, tag], {}], child.fullfilled_model)
    end

    def test_first_children
	p, c1, c2 = prepare_plan :discover => 3, :model => SimpleTask
	p.realized_by c1
	p.realized_by c2
	assert_equal([c1, c2].to_value_set, p.first_children)

	c1.signals(:start, c2, :start)
	assert_equal([c1].to_value_set, p.first_children)
    end

    def test_remove_finished_children
	p, c1, c2 = prepare_plan :discover => 3, :model => SimpleTask
        plan.permanent(p)
	p.realized_by c1
	p.realized_by c2

        p.start!
        c1.start!
        c1.success!
        p.remove_finished_children
        process_events
        assert(!plan.include?(c1))
        assert(plan.include?(c2))
    end
end
