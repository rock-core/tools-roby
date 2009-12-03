$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'

class TC_RealizedBy < Test::Unit::TestCase
    include Roby::Test

    def test_check_structure_registration
        assert plan.structure_checks.include?(Dependency.method(:check_structure))
    end

    def test_definition
	tag   = TaskModelTag.new
	klass = Class.new(SimpleTask) do
	    argument :id
	    include tag
	end
	plan.add(t1 = SimpleTask.new)

	# Check validation of the model
	child = nil
	assert_nothing_raised { t1.depends_on((child = klass.new), :model => SimpleTask) }
	assert_equal([SimpleTask, {}], t1[child, Dependency][:model])

	assert_nothing_raised { t1.depends_on klass.new, :model => [Roby::Task, {}] }
	assert_nothing_raised { t1.depends_on klass.new, :model => tag }

	plan.add(simple_task = SimpleTask.new)
	assert_raises(ArgumentError) { t1.depends_on simple_task, :model => [Class.new(Roby::Task), {}] }
	assert_raises(ArgumentError) { t1.depends_on simple_task, :model => TaskModelTag.new }
	
	# Check validation of the arguments
	plan.add(model_task = klass.new)
	assert_raises(ArgumentError) { t1.depends_on model_task, :model => [SimpleTask, {:id => 'bad'}] }

	plan.add(child = klass.new(:id => 'good'))
	assert_raises(ArgumentError) { t1.depends_on child, :model => [klass, {:id => 'bad'}] }
	assert_nothing_raised { t1.depends_on child, :model => [klass, {:id => 'good'}] }
	assert_equal([klass, { :id => 'good' }], t1[child, TaskStructure::Dependency][:model])

	# Check edge annotation
	t2 = SimpleTask.new
	t1.depends_on t2, :model => SimpleTask
	assert_equal([SimpleTask, {}], t1[t2, TaskStructure::Dependency][:model])
	t2 = klass.new(:id => 10)
	t1.depends_on t2, :model => [klass, { :id => 10 }]
    end

    Dependency = TaskStructure::Dependency

    def test_exception_printing
        parent, child = prepare_plan :add => 2, :model => SimpleTask
        parent.depends_on child
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

    # This method is a common method used in the various error/nominal tests
    # below. It creates two tasks:
    #  p1 which is an instance of SimpleTask
    #  child which is an instance of a task model with two controllable events
    #  'first' and 'second'
    #
    # p1 is a parent of child. Both tasks are started and returned.
    def create_pair(options)
	child_model = Class.new(SimpleTask) do
	    event :first, :command => true
	    event :second, :command => true
	end

	p1 = SimpleTask.new
	child = child_model.new
	plan.add([p1, child])
	p1.depends_on child, options
	plan.add_mission(p1)

	child.start!; p1.start!
        return p1, child
    end

    def assert_child_failed(child, reason, plan)
	result = plan.check_structure
	assert_equal([child].to_set, result.map { |e, _| e.exception.failed_task }.to_set)
	assert_equal([reason].to_set, result.map { |e, _| e.exception.failed_event }.to_set)
    end


    def test_success
        parent, child = create_pair :success => [:first], 
            :failure => [:stop],
            :remove_when_done => false

	assert_equal({}, plan.check_structure)
	child.first!
	assert_equal({}, plan.check_structure)
        assert(parent.depends_on?(child))
    end

    def test_success_removal
        parent, child = create_pair :success => [:first], 
            :failure => [:stop],
            :remove_when_done => true

	child.first!
	assert_equal({}, plan.check_structure)
        assert(!parent.depends_on?(child))
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
	assert_child_failed(child, child.event(:failed).last, plan)
        plan.clear
    end

    def test_fullfilled_model_validation
	tag = TaskModelTag.new
	klass = Class.new(Roby::Task)

	p1, p2, child = prepare_plan :add => 3, :model => SimpleTask
	p1.depends_on child, :model => [SimpleTask, { :id => "discover-3" }]
        p2.depends_on child, :model => [SimpleTask, { :id => 'discover-3' }]

        # Mess with the relation definition
        p1[child, Dependency][:model].last[:id] = 'discover-10'
        assert_raises(ModelViolation) { child.fullfilled_model }
        p1[child, Dependency][:model] = [klass, {}]
        assert_raises(ModelViolation) { child.fullfilled_model }
    end

    def test_fullfilled_model
	tag = TaskModelTag.new
	klass = Class.new(SimpleTask) do
	    include tag
	end

	p1, p2, child = prepare_plan :add => 3, :model => klass

	p1.depends_on child, :model => [SimpleTask, { :id => "discover-3" }]
	p2.depends_on child, :model => Roby::Task
	assert_equal([[SimpleTask], {:id => 'discover-3'}], child.fullfilled_model)
	p1.remove_child(child)
	assert_equal([[Roby::Task], {}], child.fullfilled_model)
	p1.depends_on child, :model => tag
	assert_equal([[Roby::Task, tag], {}], child.fullfilled_model)
	p2.remove_child(child)
	p2.depends_on child, :model => [klass, { :id => 'discover-3' }]
	assert_equal([[klass, tag], {:id => 'discover-3'}], child.fullfilled_model)
    end

    def test_first_children
	p, c1, c2 = prepare_plan :add => 3, :model => SimpleTask
	p.depends_on c1
	p.depends_on c2
	assert_equal([c1, c2].to_value_set, p.first_children)

	c1.signals(:start, c2, :start)
	assert_equal([c1].to_value_set, p.first_children)
    end

    def test_remove_finished_children
	p, c1, c2 = prepare_plan :add => 3, :model => SimpleTask
        plan.add_permanent(p)
	p.depends_on c1
	p.depends_on c2

        p.start!
        c1.start!
        c1.success!
        p.remove_finished_children
        process_events
        assert(!plan.include?(c1))
        assert(plan.include?(c2))
    end
end
