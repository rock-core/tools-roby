require 'test/unit'
require 'test_config'
require 'pp'
require 'roby/planning'
require 'roby/relations/planned_by'
require 'flexmock'

class TC_Planner < Test::Unit::TestCase
    include Roby
    include Roby::Planning

    def setup
	Planner.last_id = 0 
	new_plan
    end
    def teardown
	Planner.last_id = 0 
	plan.clear if plan
    end

    attr_reader :plan
    def new_plan
	plan.clear if plan
	@plan = Plan.new
    end

    def test_id_validation
	assert_equal(15, Planner.validate_method_id("15"))
	assert_equal('foo', Planner.validate_method_id(:foo))
	assert_equal('foo', Planner.validate_method_id('foo'))
    end

    def test_method_definition
	base_model, base_1, base_15, base_foobar, base_barfoo, recursive = nil
        model = Class.new(Planner) do 
	    base_model = method(:base)
            base_1 = method(:base) { NullTask.new }
            base_15 = method(:base, :id => "15") { NullTask.new }
            base_foobar = method(:base, :id => :foobar) { NullTask.new }
            base_barfoo = method(:base, :id => 'barfoo') { NullTask.new }
            recursive = method(:recursive, :recursive => true) { NullTask.new }
        end
	assert_equal(17, model.next_id)
	
	assert(model.respond_to?(:base_methods))
	assert(model.respond_to?(:each_base_method), model.methods.find_all { |name| name =~ /base/ }.inspect)
	assert_equal({ 1 => base_1, 15 => base_15, "foobar" => base_foobar, "barfoo" => base_barfoo }.to_set, model.enum_for(:each_base_method).to_set)

	assert(model.respond_to?(:base_model))

	assert(model.find_methods(:base))
	assert_equal(4, model.find_methods(:base).size)
	assert_equal(1, model.find_methods(:base, :id => 1).size)
	assert_equal(1, model.find_methods(:base, :id => 15).size) # Check handling of the string -> integer convertion
	assert_equal(1, model.find_methods(:base, :id => 'foobar').size) # Check handling of the symbol -> string convertion
	assert_equal(1, model.find_methods(:base, :id => :barfoo).size)

	assert_equal(nil, model.find_methods('recursive', :recursive => false))
	assert_equal([recursive], model.find_methods('recursive', :recursive => true))

        planner = model.new(plan)
        assert(planner.respond_to?(:base))
        assert(planner.base.null?)
        assert(planner.respond_to?(:recursive))
	assert_raises(Planning::NotFound) { planner.recursive(:recursive => false) }
    end

    def test_reuse
	task_model = Class.new(Task)
	derived_model = Class.new(task_model)
	planner_model = Class.new(Planner) do
	    method(:reusable, :returns => task_model)
	    method(:not_reusable, :returns => task_model, :reuse => false)
	end
	assert_raise(ArgumentError) { planner_model.method(:not_reusable, :reuse => true) }
	assert_nothing_raised { planner_model.method(:not_reusable, :reuse => false) }
	assert_nothing_raised { planner_model.method(:reusable, :reuse => true) }

	planner_model.class_eval do
	    method(:reusable, :id => 'base')	    { task_model.new }
	    method(:reusable, :id => 'derived', :returns => derived_model) { derived_model.new }
	    method(:not_reusable)   { task_model.new }

	    # This one should build two tasks
	    method(:check_not_reusable, :id => 1) do
		[reusable(:id => 'base'), not_reusable]
	    end
	    
	    # This one should build two tasks
	    method(:check_not_reusable, :id => 2) do
		[not_reusable, not_reusable]
	    end

	    # This one should build one task
	    method(:check_reusable, :id => 1) do
		[not_reusable, reusable(:id => 'base')]
	    end

	    # This one should build only one task
	    method(:check_reusable, :id => 2) do
		[reusable(:id => 'base'), reusable(:id => 'base')]
	    end

	    # This one whouls build two tasks
	    method(:check_reusable, :id => 3) do
		[reusable(:id => 'base'), reusable(:id => 'derived')]
	    end
	    
	    # This one whouls build one task
	    method(:check_reusable, :id => 4) do
		[reusable(:id => 'derived'), reusable(:id => 'base')]
	    end
	end

	assert_result_plan_size(1, planner_model, :check_reusable, :id => 1)
	assert_result_plan_size(1, planner_model, :check_reusable, :id => 2)
	assert_result_plan_size(2, planner_model, :check_reusable, :id => 3)
	assert_result_plan_size(1, planner_model, :check_reusable, :id => 4)

	assert_result_plan_size(2, planner_model, :check_not_reusable, :id => 1)
	assert_result_plan_size(2, planner_model, :check_not_reusable, :id => 2)
    end
    def assert_result_plan_size(size, planner_model, method, options)
	planner = planner_model.new(plan)
	result = planner.send(method, options)
	planner.plan.insert(result)
	assert_equal(size, planner.plan.size, planner.plan.known_tasks.to_a.inspect)

	plan.clear
    end

    def test_recursive
	t_not_rec = Class.new(Task)
	t_rec = Class.new(Task)
        model = Class.new(Planner) do
            method(:not_recursive) { root }
            method(:recursive, :recursive => true) { root }
            method(:root, :recursive => true) do
                recursive + not_recursive
            end
        end

        planner = model.new(plan)
        assert(planner.has_method?(:recursive))
        assert(planner.respond_to?(:recursive))
        recursive = planner.class.find_methods(:recursive)
        assert_equal(1, recursive.size)
        assert(recursive.first.recursive?)

	# Calls:
	#   not_recursive
	#    - root
	#	- recursive
	#	- not_recursive <= FAILS HERE
        assert_raises(NotFound) { model.new(new_plan).not_recursive }

	# Calls:
	#   recursive
	#    - root
	#	- recursive => Task (with a planning task)
	#	- not_recursive
	#	    - root => Task (with a planning task)
        planner = model.new(new_plan)
        assert_nothing_raised { planner.recursive }
        tasks = planner.plan.enum_for(:each_task).to_a
	assert_equal(5, tasks.size)
        planners = tasks.find_all { |node| PlanningTask === node }
        assert_equal ['recursive', 'root'].to_set, planners.map { |t| t.method_name }.to_set
	assert_equal [Task, Task].to_set, planners.map { |t| t.planned_task.class }.to_set
    end

    def test_method_model
	# Some task models
        tm_a = Class.new(Roby::Task)
        tm_a_a = Class.new(tm_a)
        tm_b = Class.new(Roby::Task)
        foo_klass = Class.new

	# The planning model
        model = Class.new(Planner)
	
	# Fails because foo_klass is not a task
	assert_raises(ArgumentError) { model.method(:root, :returns => foo_klass) }
	# Check the definition of instance methods on Planner instances
	model.method(:root, :returns => tm_a)
	assert_equal( model.root_model, model.method_model(:root) )
	assert_equal(tm_a, model.method_model(:root).returns)
	# Fails because we can't override a :returns option
	assert_raises(ArgumentError) { model.method(:root, :returns => tm_b) }
	# Does not fail since tm_a is the curren :returns task model
	assert_nothing_raised { model.method(:root, :returns => tm_a) }

	# Check that :returns is properly validated on methods
	model.method(:root, :id => 1) {}
	assert_raises(ArgumentError) { model.method(:root, :returns => tm_b) {} }
	assert_nothing_raised { model.method(:root, :returns => tm_a) {} }
	assert_nothing_raised { model.method(:root, :returns => tm_a_a) {} }

	# Cannot redefine the model since there are methods
	assert_raises(ArgumentError) { model.method(:root, :returns => tm_a) }

	# Check that we can't override an already-defined method
	assert_raises(ArgumentError) { model.method(:root, :id => 1) {} }
    end

    def test_model_of
        tm1 = Class.new(Roby::Task)
	tm2 = Class.new(tm1)
	tm3 = Class.new(tm2)
	base = Class.new(Planner) do
	    method(:root, :returns => tm1)
	    method(:root, :id => 'nil') { }
	    method(:root, :id => 'tm2', :returns => tm2) { }
	end
	derived = Class.new(base) do
	    method(:root, :id => 'derived', :returns => tm2) { }
	end

	assert_equal(tm1, base.model_of(:root).returns)
	assert_equal(tm1, base.model_of(:root, :id => 'nil').returns)
	assert_equal(tm2, base.model_of(:root, :id => 'tm2').returns)
	assert_equal(tm1, derived.model_of(:root).returns)
	assert_equal(tm1, derived.model_of(:root, :id => 'nil').returns)
	assert_equal(tm2, derived.model_of(:root, :id => 'tm2').returns)
	assert_equal(tm2, derived.model_of(:root, :id => 'derived').returns)
    end

    def test_returns_inheritance
	# Some task models
        tm_a = Class.new(Roby::Task)
        tm_a_a = Class.new(tm_a)
        tm_b = Class.new(Roby::Task)
        foo_klass = Class.new

	# The planning models
        base = Class.new(Planner)
	base.method(:root, :returns => tm_a)
	derived = Class.new(base)

	# Check that we can override the model on derived
	assert_raises(ArgumentError) { derived.method(:root, :returns => tm_b) }
	assert_nothing_raised { derived.method(:root, :returns => tm_a_a) }
	assert_equal(base.root_model.returns, tm_a)
	assert_equal(derived.root_model.returns, tm_a_a)
    end

    def test_method_inheritance
	# Define a few task models
        tm_a	    = Class.new(Roby::Task)
        tm_b	    = Class.new(Roby::Task)
        tm_a_a	    = Class.new(tm_a)
        tm_a_a_a    = Class.new(tm_a_a)
        tm_b_a	    = Class.new(tm_a)

        base = Class.new(Planner) do
            method(:root, :returns => tm_a)
            method(:root, :id => 1, :returns => tm_a_a) {}
	end
	base_root = base.enum_for(:each_root_method).to_a

        d1 = Class.new(base)
	# There are methods defined on :root, cannot override the :returns option
	assert_raises(ArgumentError)	{ d1.method(:root, :returns => tm_a_a) }
	assert_raises(ArgumentError)	{ d1.method(:root, :returns => tm_b) }
	assert_raises(ArgumentError)	{ d1.method(:root, :returns => tm_b) {} }

	d1_root = []
	# Define a few methods and check :returns is validated properly
	assert_nothing_raised { d1_root << d1.method(:root, :returns => tm_a) {} }
	assert_nothing_raised { d1_root << d1.method(:root, :returns => tm_a_a) {} }
	assert_nothing_raised { d1_root << d1.method(:root, :returns => tm_b_a) {} }
	d2_root = d1_root.dup
	assert_nothing_raised { d1_root << d1.method(:root, :id => 1, :returns => tm_a_a) {} }

	d2 = Class.new(d1)
	assert_nothing_raised { d2_root << d2.method(:root, :id => 1, :returns => tm_a_a_a) {} }

	# Check that methods are defined at the proper level in the class hierarchy
	assert_equal(base_root.to_set, base.enum_for(:each_root_method).to_set)
	assert_equal(d1_root.to_set, d1.enum_for(:each_root_method).map { |_, x| x }.to_set)
	assert_equal(d2_root.to_set, d2.enum_for(:each_root_method).map { |_, x| x }.to_set)
    end

    def test_library
	a = Planning::Library.new do
	    method(:root, :id => 'a') { }
	end
	b = Planning::Library.new do
	    include a
	    method(:root, :id => 'b') { }
	end

	planner = Class.new(Planner) do
	    include b
	end

	assert( planner.find_methods(:root) )
	assert_equal(['a', 'b'], planner.find_methods(:root).map { |m| m.id } )

	c = Module.new do
	    planning_library
	    using a
	end
	planner = Class.new(Planner) { include c }
	assert_equal(['a'], planner.find_methods(:root).map { |m| m.id } )

	d = Module.new do
	    include b
	end
	assert_nothing_raised { d.method(:root, :id => 'c') { } }
    end

    def test_return_type
	task_model = Class.new(Task)
	planner = Class.new(Planner) do
	    method(:test, :returns => task_model)
	    method(:test, :id => "good") { task_model.new }
	    method(:test, :id => "bad", :reuse => false) { NullTask.new }
	    method(:not_a_task, :reuse => false) { nil }
	end.new(plan)
	assert_nothing_raised { planner.test(:id => "good") }
	assert_raises(Planning::NotFound) { planner.test(:id => "bad") }
	assert_raises(Planning::NotFound) { planner.not_a_task }
    end

    def test_method_filter
	base = Class.new(Planner) do
	    method(:test, :id => 1) { arguments[:mock].m(1) }
	    method(:test, :id => 2) { arguments[:mock].m(2) }
	end

	filter_block = lambda { true }
	planner = Class.new(base) do
	    filter(:test, &filter_block)
	end
	assert(planner.respond_to?(:each_test_filter))
	assert_equal([filter_block], planner.enum_for(:each_test_filter).to_a)
	assert_equal(2, planner.find_methods('test', :index => 10).size)

	planner = Class.new(base) do
	    filter(:test) { false }
	end
	assert(!planner.find_methods('test', :index => 10))
	
	
	(1..2).each do |i|
	    FlexMock.use do |mock|
		planner = Class.new(base) do
		    filter(:test) do |m| 
			mock.filtered(m.id)
			m.id == i 
		    end
		end.new(plan)

		mock.should_receive(:m).with(i).once.returns(NullTask.new)
		mock.should_receive(:filtered).with(2).once
		mock.should_receive(:filtered).with(1).once
		planner.test(:mock => mock)
	    end
	end
	
	planner = Class.new(base) do
	    filter(:test) { false }
	end.new(plan)
	assert_raises(Planning::NotFound) { planner.test }
    end

    def test_planning_task_one_shot
	result_task = ExecutableTask.new
	planner = Class.new(Planning::Planner) do
	    method(:task) { result_task }
	end

	planning_task = PlanningTask.new(plan, planner, :task, {})
	planned_task = Task.new
	planned_task.planned_by planning_task
	plan.insert(planned_task)

	planning_task.on(:success, planned_task, :start)
	planning_task.start!

        poll(0.5) do
            thread_finished = !planning_task.thread.alive?
            Control.instance.process_events
            assert(planning_task.running? ^ thread_finished)
            break unless planning_task.running?
        end

	plan_task = plan.missions.find { true }
        assert(plan_task == result_task, plan_task)
    end




    def check_loop_planning_task(loop_planner, initial_planner, planner_model)
	loop_tasks = loop_planner.children
	
	# Check that we have one planned task and one non-planned task
	assert_equal(2, loop_tasks.size)
	loop_tasks.delete(initial_planner.result_task)

	nonplanned_task = *loop_tasks
	planning_task = nonplanned_task.planning_task
	assert_kind_of(Task          , nonplanned_task)
	assert_equal([planning_task] , loop_planner.enum_for(:each_pattern_planning).to_a)
	assert_equal(planning_task   , loop_planner.last_planning_task)
	assert_equal(nonplanned_task , loop_planner.last_planned_task)
	assert_equal(planner_model   , planning_task.planner.class)

	# Start the loop and check that #reschedule works as expected
	loop_planner.start!
	assert(initial_planner.result_task.running?)
	assert(planning_task.running?)
	
	# Wait for the planner to finish
	poll(0.5) do
	    thread_finished = !planning_task.thread.alive?
	    Control.instance.process_events

	    assert(planning_task.running? ^ thread_finished, [planning_task.finished?, thread_finished].inspect)
	    break if planning_task.finished?
	end

	assert_kind_of(SimpleTask, planning_task.planned_task)
	assert_equal(planning_task.planned_task, planning_task.planner.result_task)
    end

    def test_loop_planning_task
	planner_model = Class.new(Planning::Planner) do
	    @result_task = nil
	    attr_reader :result_task
	    method(:task) { @result_task = SimpleTask.new }
	end

	initial_planner = planner_model.new(plan)
	loop_planner = PlanningLoop.new(0, 1, plan, initial_planner, :task)
	check_loop_planning_task(loop_planner, initial_planner, planner_model)
    end

    def test_make_loop
	planner_model = Class.new(Planning::Planner) do
	    @result_task = nil
	    attr_reader :result_task
	    method(:task) {  @result_task = SimpleTask.new }
	    method(:my_looping_task) do
		make_loop(0) do
		    task
		end
	    end
	end

	initial_planner = planner_model.new(plan)
	loop_planner = initial_planner.my_looping_task
	check_loop_planning_task(loop_planner, initial_planner, planner_model)
    end
end

