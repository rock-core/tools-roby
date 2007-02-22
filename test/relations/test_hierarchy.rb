$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'test_config'
require 'mockups/tasks'

require 'roby/relations/hierarchy'
require 'roby/plan'

class TC_RealizedBy < Test::Unit::TestCase
    include RobyTestCommon

    attr_reader :plan
    def setup
	@plan = Plan.new
	super
    end

    def test_definition
	t1 = SimpleTask.new

	# Check validation of the :model argument
	assert_nothing_raised { t1.realized_by SimpleTask.new, :model => SimpleTask }
	assert_nothing_raised { t1.realized_by SimpleTask.new, :model => [Roby::Task, {}] }
	assert_raises(ArgumentError) { t1.realized_by SimpleTask.new, :model => [Class.new(Roby::Task), {}] }

	# Check edge annotation
	t2 = SimpleTask.new
	t1.realized_by t2, :model => SimpleTask
	assert_equal([SimpleTask, {}], t1[t2, TaskStructure::Hierarchy][:model])

	t2 = SimpleTask.new
	t1.realized_by t2, :model => [SimpleTask, { :value => 10 }]
	assert_equal([SimpleTask, { :value => 10 }], t1[t2, TaskStructure::Hierarchy][:model])
    end

    Hierarchy = TaskStructure::Hierarchy

    def assert_children_failed(children, plan)
	result = Hierarchy.check_structure(plan)
	assert_equal(children.size, result.size)
	assert_equal(children.to_set, result.map { |e| e.task }.to_set)
    end

    def test_structure_checking
	child_model = Class.new(SimpleTask) do
	    event :first, :command => true
	    event :second, :command => true
	end

	p1 = SimpleTask.new
	child = child_model.new
	p1.realized_by child
	plan.insert(p1)

	child.start!; p1.start!
	assert_equal([], Hierarchy.check_structure(plan))
	child.stop!
	assert_children_failed([child], plan)

	plan.clear
	p1 = SimpleTask.new
	child = child_model.new
	p1.realized_by child, :success => [:second], :failure => [:first]
	plan.insert(p1)
	child.start! ; p1.start!
	child.event(:first).emit(nil)
	assert_children_failed([child], plan)

	plan.clear
	p1    = SimpleTask.new
	child = child_model.new
	p1.realized_by child, :success => [:first], :failure => [:second]
	plan.insert(p1)
	child.start! ; p1.start!
	child.event(:first).emit(nil)
	assert_children_failed([], plan)
	child.event(:second).emit(nil)
	assert_children_failed([], plan)
    end

    def test_fullfilled_model
	p1, p2, child = (1..3).map { SimpleTask.new }
	p1.realized_by child, :model => SimpleTask
	p2.realized_by child, :model => Roby::Task
	assert_equal([SimpleTask, {}], child.fullfilled_model)
	p1.remove_child(child)
	assert_equal([Roby::Task, {}], child.fullfilled_model)
    end

    def test_first_children
	p, c1, c2 = (1..3).map { SimpleTask.new }
	p.realized_by c1
	p.realized_by c2
	assert_equal([c1, c2].to_value_set, p.first_children)

	c1.on(:start, c2, :start)
	assert_equal([c1].to_value_set, p.first_children)
    end
end
