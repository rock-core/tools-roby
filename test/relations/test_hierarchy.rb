$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'

class TC_RealizedBy < Test::Unit::TestCase
    include Roby::Test

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

	assert_same(Hierarchy.interesting_events, EventGenerator.event_gathering[child.event(:success)].find { true })
	assert_same(Hierarchy.interesting_events, EventGenerator.event_gathering[child.event(:failed)].find { true })
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

    def assert_children_failed(children, plan)
	result = Hierarchy.check_structure(plan)
	assert_equal(children.to_set, result.map { |e| e.task }.to_set)
    end

    def test_structure_checking
	child_model = Class.new(SimpleTask) do
	    event :first, :command => true
	    event :second, :command => true
	end

	p1 = SimpleTask.new
	child = child_model.new
	plan.discover([p1, child])
	p1.realized_by child
	plan.insert(p1)

	child.start!; p1.start!
	assert_equal([], Hierarchy.check_structure(plan))
	child.stop!
	assert_equal([child.event(:failed).last], Hierarchy.interesting_events)
	assert_children_failed([child], plan)

	plan.clear
	p1 = SimpleTask.new
	child = child_model.new
	plan.discover([p1, child])
	p1.realized_by child, :success => [:second], :failure => [:first]
	plan.insert(p1)
	child.start! ; p1.start!
	child.event(:first).emit(nil)
	assert_children_failed([child], plan)

	plan.clear
	p1    = SimpleTask.new
	child = child_model.new
	plan.discover([p1, child])
	p1.realized_by child, :success => [:first], :failure => [:second]
	plan.insert(p1)
	child.start! ; p1.start!
	child.event(:first).emit(nil)
	assert_children_failed([], plan)
	child.event(:second).emit(nil)
	assert_children_failed([], plan)
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

	c1.on(:start, c2, :start)
	assert_equal([c1].to_value_set, p.first_children)
    end
end
