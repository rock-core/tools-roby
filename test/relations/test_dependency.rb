$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'
require 'flexmock'

class TC_RealizedBy < Test::Unit::TestCase
    include Roby::Test

    # Set to true to have the tests display the pretty-printed errors.
    DISPLAY_FORMATTED_ERRORS = false

    def test_check_structure_registration
        assert plan.structure_checks.include?(Dependency.method(:check_structure))
    end

    def assert_formatting_succeeds(object)
        message = Roby.format_exception(object)
        if DISPLAY_FORMATTED_ERRORS
            puts message.join("\n")
        end
    end

    def test_definition
	tag   = TaskModelTag.new
	klass = Class.new(Tasks::Simple) do
	    argument :id
	    include tag
	end
	plan.add(t1 = Tasks::Simple.new)

	# Check validation of the model
	child = nil
	t1.depends_on((child = klass.new), :model => Tasks::Simple)
	assert_equal([Tasks::Simple, {}], t1[child, Dependency][:model])

	t1.depends_on klass.new, :model => [Roby::Task, {}]
	t1.depends_on klass.new, :model => tag

	plan.add(simple_task = Tasks::Simple.new)
	assert_raises(ArgumentError) { t1.depends_on simple_task, :model => [Class.new(Roby::Task), {}] }
	assert_raises(ArgumentError) { t1.depends_on simple_task, :model => TaskModelTag.new }
	
	# Check validation of the arguments
	plan.add(model_task = klass.new)
	assert_raises(ArgumentError) { t1.depends_on model_task, :model => [Tasks::Simple, {:id => 'bad'}] }

	plan.add(child = klass.new(:id => 'good'))
	assert_raises(ArgumentError) { t1.depends_on child, :model => [klass, {:id => 'bad'}] }
	assert_nothing_raised { t1.depends_on child, :model => [klass, {:id => 'good'}] }
	assert_equal([klass, { :id => 'good' }], t1[child, TaskStructure::Dependency][:model])

	# Check edge annotation
	t2 = Tasks::Simple.new
	t1.depends_on t2, :model => Tasks::Simple
	assert_equal([Tasks::Simple, {}], t1[t2, TaskStructure::Dependency][:model])
	t2 = klass.new(:id => 10)
	t1.depends_on t2, :model => [klass, { :id => 10 }]
    end

    Dependency = TaskStructure::Dependency

    def test_exception_printing
        parent, child = prepare_plan :add => 2, :model => Tasks::Simple
        parent.depends_on child
        parent.start!
        child.start!
        child.failed!

	error = plan.check_structure.find { true }[0].exception
	assert_kind_of(ChildFailedError, error)
        assert_formatting_succeeds(error)

        parent.stop!
    end

    # This method is a common method used in the various error/nominal tests
    # below. It creates two tasks:
    #  p1 which is an instance of Tasks::Simple
    #  child which is an instance of a task model with two controllable events
    #  'first' and 'second'
    #
    # p1 is a parent of child. Both tasks are started and returned.
    def create_pair(options)
	child_model = Class.new(Tasks::Simple) do
	    event :first, :command => true
	    event :second, :command => true
	end

	p1 = Tasks::Simple.new
	child = child_model.new
	plan.add([p1, child])
	p1.depends_on child, options
	plan.add_mission(p1)

	child.start!; p1.start!
        return p1, child
    end

    def assert_child_failed(child, reason, plan)
	result = plan.check_structure
        if result.size != 1
            flunk("error set expected to be of size 1, is #{errors.size}")
        end
        error = result.find { true }[0].exception
	assert_equal(child, error.failed_task)
	assert_equal(reason, error.failure_point)
        assert_formatting_succeeds(error)
        error
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

    def test_failure_on_failed_start
        plan.add(parent = Tasks::Simple.new)
        model = Class.new(Tasks::Simple) do
            event :start do |context|
                raise ArgumentError
            end
        end
        plan.add(child = model.new(:id => 10))
        parent.depends_on child
        parent.start!
        child.start!

	exception = assert_child_failed(child, child.event(:success), plan)
        plan.clear
    end

    def test_failure_on_unreachable
        parent, child = create_pair :success => [:first]

        child.stop!
	error = assert_child_failed(child, child.failed_event.last, plan)
        assert_equal(nil, error.explanation.value)
        plan.clear
    end

    def test_fullfilled_model_validation
	tag = TaskModelTag.new
	klass = Class.new(Roby::Task)

	p1, p2, child = prepare_plan :add => 3, :model => Tasks::Simple
	p1.depends_on child, :model => [Tasks::Simple, { :id => "discover-3" }]
        p2.depends_on child, :model => [Tasks::Simple, { :id => 'discover-3' }]

        # Mess with the relation definition
        p1[child, Dependency][:model].last[:id] = 'discover-10'
        assert_raises(ModelViolation) { child.fullfilled_model }
        p1[child, Dependency][:model] = [klass, {}]
        assert_raises(ModelViolation) { child.fullfilled_model }
    end

    def test_fullfilled_model
	tag = TaskModelTag.new
	klass = Class.new(Tasks::Simple) do
	    include tag
	end

	p1, p2, child = prepare_plan :add => 3, :model => klass

	p1.depends_on child, :model => [Tasks::Simple, { :id => "discover-3" }]
	p2.depends_on child, :model => Roby::Task
	assert_equal([[Tasks::Simple], {:id => 'discover-3'}], child.fullfilled_model)
	p1.remove_child(child)
	assert_equal([[Roby::Task], {}], child.fullfilled_model)
	p1.depends_on child, :model => tag
	assert_equal([[Roby::Task, tag], {}], child.fullfilled_model)
	p2.remove_child(child)
	p2.depends_on child, :model => [klass, { :id => 'discover-3' }]
	assert_equal([[klass, tag], {:id => 'discover-3'}], child.fullfilled_model)
    end

    def test_fullfilled_model_transaction
	tag = TaskModelTag.new
	klass = Class.new(Tasks::Simple) do
	    include tag
	end

	p1, p2, child = prepare_plan :add => 3, :model => Class.new(klass)
        trsc = Transaction.new(plan)

	p1.depends_on child, :model => [Tasks::Simple, { :id => "discover-3" }]
	p2.depends_on child, :model => klass

        t_child = trsc[child]
        assert_equal([[klass], {:id => "discover-3"}], t_child.fullfilled_model)
        t_p2 = trsc[p2]
        assert_equal([[klass], {:id => "discover-3"}], t_child.fullfilled_model)
        t_p2.remove_child(t_child)
        assert_equal([[Tasks::Simple], { :id => 'discover-3' }], t_child.fullfilled_model)
	t_p2.depends_on t_child, :model => klass
        assert_equal([[klass], { :id => 'discover-3' }], t_child.fullfilled_model)
        trsc.remove_object(t_p2)
        assert_equal([[klass], { :id => 'discover-3' }], t_child.fullfilled_model)
    end

    def test_first_children
	p, c1, c2 = prepare_plan :add => 3, :model => Tasks::Simple
	p.depends_on c1
	p.depends_on c2
	assert_equal([c1, c2].to_value_set, p.first_children)

	c1.signals(:start, c2, :start)
	assert_equal([c1].to_value_set, p.first_children)
    end

    def test_remove_finished_children
	p, c1, c2 = prepare_plan :add => 3, :model => Tasks::Simple
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

    def test_role_definition
        plan.add(parent = Tasks::Simple.new)

        child = Tasks::Simple.new
        parent.depends_on child, :role => 'child1'
        assert_equal(['child1'].to_set, parent.roles_of(child))

        child = Tasks::Simple.new
        parent.depends_on child, :roles => ['child1', 'child2']
        assert_equal(['child1', 'child2'].to_set, parent.roles_of(child))
    end

    def setup_merging_test(special_options = Hash.new)
        plan.add(parent = Tasks::Simple.new)
        tag = TaskModelTag.new
        intermediate = Class.new(Tasks::Simple)
        intermediate.include tag
        child_model = Class.new(intermediate)
        child = child_model.new(:id => 'child')

        options = { :role => 'child1', :model => Task, :success => [], :failure => [] }.
            merge(special_options)
        parent.depends_on child, options

        expected_info = { :remove_when_done=>true,
            :model => [Roby::Task, {}],
            :roles => ['child1'].to_set,
            :success=>false.to_unbound_task_predicate,
            :failure=>false.to_unbound_task_predicate }.merge(special_options)
        assert_equal expected_info, parent[child, Dependency]

        return parent, child, expected_info, child_model, tag
    end

    def test_merging_events
        parent, child, info, child_model, _ = setup_merging_test(:success => :success.to_unbound_task_predicate)
        parent.depends_on child, :success => [:success]
        info[:model] = [child_model, {:id => 'child'}]
        info[:success] = :success.to_unbound_task_predicate
        assert_equal info, parent[child, Dependency]

        parent.depends_on child, :success => [:stop]
        info[:success] = info[:success].and(:stop.to_unbound_task_predicate)
        assert_equal info, parent[child, Dependency]

        parent.depends_on child, :failure => [:stop]
        info[:failure] = :stop.to_unbound_task_predicate
        assert_equal info, parent[child, Dependency]
    end
    
    def test_merging_remove_when_done_cannot_change
        parent, child, info, _ = setup_merging_test
        assert_raises(ModelViolation) { parent.depends_on child, :remove_when_done => false }
        parent.depends_on child, :model => info[:model], :remove_when_done => true, :success => []
        assert_equal info, parent[child, Dependency]
    end

    def test_merging_models
        parent, child, info, child_model, tag = setup_merging_test

        # Test that models are "upgraded"
        parent.depends_on child, :model => Tasks::Simple, :success => []
        info[:model][0] = Tasks::Simple
        assert_equal info, parent[child, Dependency]
        parent.depends_on child, :model => Roby::Task, :remove_when_done => true, :success => []
        assert_equal info, parent[child, Dependency]

        # Test that arguments are merged
        parent.depends_on child, :model => [Tasks::Simple, {:id => 'child'}], :success => []
        info[:model][1] = {:id => 'child'}
        assert_equal info, parent[child, Dependency]
        # note: arguments can't be changed on the task *and* #depends_on
        # validates them, so we don't need to test that.

        # Test model/tag handling: #depends_on should find the most generic
        # model matching +task+ that includes all required models
        parent.depends_on child, :model => tag, :success => []
        info[:model][0] = child_model.superclass
        assert_equal info, parent[child, Dependency]
    end

    def test_merging_roles
        parent, child, info, _ = setup_merging_test

        parent.depends_on child, :model => Roby::Task, :role => 'child2', :success => []
        info[:roles] << 'child2'
        assert_equal info, parent[child, Dependency]
    end
end

