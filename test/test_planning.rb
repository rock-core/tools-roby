$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/planning'

require 'flexmock'
require 'mockups/tasks'

class TC_Planner < Test::Unit::TestCase
    include Roby::Planning
    include Roby::Test

    def test_id_validation
	assert_equal(15, Planner.validate_method_id("15"))
	assert_equal('foo', Planner.validate_method_id(:foo))
	assert_equal('foo', Planner.validate_method_id('foo'))
    end

    def test_method_definition
	base_model, base_1, base_15, base_foobar, base_barfoo, recursive = nil
        model = Class.new(Planner) do 
	    base_model  = method(:base)
	    base_1      = method(:base) { NullTask.new }
	    base_15     = method(:base, :id => "15") { NullTask.new }
	    base_foobar = method(:base, :id => :foobar) { NullTask.new }
	    base_barfoo = method(:base, :id => 'barfoo') { NullTask.new }
	    recursive   = method(:recursive, :recursive => true) { NullTask.new }
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

    def test_empty_method_set
	task_model = Class.new(Roby::Task)
	model = Class.new(Roby::Planning::Planner) do
	    method(:empty_set, :returns => task_model)
	end

	planner = model.new(plan)
	assert_raises(NotFound) { planner.empty_set }

	plan.insert(task = task_model.new)
	found_task = nil
	assert_nothing_raised { found_task = planner.empty_set }
	assert_equal(found_task, task)
	assert_raises(NotFound) { planner.empty_set :reuse => false }
    end

    def assert_result_plan_size(size, planner_model, method, options)
	planner = planner_model.new(plan)
	result = planner.send(method, options)
	result.each do |task|
	    planner.plan.insert(task)
	end
	assert_equal(size, planner.plan.size, planner.plan.known_tasks.to_a.inspect)

	new_plan
    end

    def test_recursive
	task_model = Class.new(Roby::Task) do
	    argument :id
	end

        model = Class.new(Planner) do
            method(:not_recursive) { root }
            method(:recursive, :recursive => true) do
		if @rec_already_called
		    task_model.new(:id => 'recursive')
		else
		    @rec_already_called = true
		    root
		end
	    end
            method(:root, :recursive => true) do
		if @root_already_called
		    task_model.new(:id => 'root')
		else
		    @root_already_called = true
		    [recursive, not_recursive]
		end
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
	#	- recursive => Task(id: recursive)
	#	- not_recursive
	#	    - root => Task(id: root)
        planner = model.new(new_plan)
        assert_nothing_raised { planner.recursive }
	assert_equal(2, plan.size, plan.known_tasks)
	assert_equal(1, plan.find_tasks.which_fullfills(task_model, :id => 'recursive').to_a.size)
	assert_equal(1, plan.find_tasks.which_fullfills(task_model, :id => 'root').to_a.size)
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

    def test_returns_validation
        task_model = Class.new(Roby::Task)
	task_tag   = TaskModelTag.new

	planner_model = Class.new(Planning::Planner)
	assert_nothing_raised { planner_model.method(:returns_task, :returns => task_model) }
	assert_nothing_raised { planner_model.method(:returns_tag, :returns => task_tag) }
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
	task_model = Class.new(Task) do
	    argument :arg
	end
	planner = Class.new(Planner) do
	    method(:test, :returns => task_model, :reuse => false)
	    method(:test, :id => "good") { task_model.new(:arg => 42, :unmatched => 21) }
	    method(:test, :id => "bad_argument") { task_model.new(:arg => 21) }
	    method(:test, :id => "bad_model") { NullTask.new(:arg => 42) }
	    method(:test, :id => "array") { [task_model.new] }
	    method(:not_a_task) { nil }
	end.new(plan)
	assert_nothing_raised { planner.test(:id => "good", :arg => 42, :unmatched => 10) }
	assert_raises(Planning::NotFound) { planner.test(:id => "bad_argument", :arg => 42) }
	assert_raises(Planning::NotFound) { planner.test(:id => "bad_model", :arg => 42) }
	assert_raises(Planning::NotFound) { planner.test(:id => "array", :arg => 42) }
	assert_raises(Planning::NotFound) { planner.not_a_task }
    end

    def test_planning_methods_names
	model = Class.new(Planner) do
	    def not_a_planning_method
	    end
	    method(:test) { }
	    method(:localization) { }
	    method(:model_only)
	end
	assert_equal(['test', 'localization', 'model_only'].to_set, 
		     model.planning_methods_names.to_set)
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
		    filter(:test) do |opt, m| 
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
	result_task = SimpleTask.new
	planner = Class.new(Planning::Planner) do
	    method(:task) do
		raise unless arguments[:context] == 42
		result_task
	    end
	end

	planning_task = PlanningTask.new(:planner_model => planner, :method_name => :task)
	plan.insert(planned_task = Task.new)
	planned_task.planned_by planning_task

	planning_task.on(:success, planned_task, :start)
	planning_task.start!(42)
	planning_task.thread.join
	process_events

	plan_task = plan.missions.find { true }
        assert_equal(result_task, plan_task)
	assert_equal(result_task, planning_task.planned_task)
    end

    def planning_loop_next(main_task)
	assert(task = main_task.children.find { |t| t.planning_task.running? })
	planner = task.planning_task
	planner.thread.join
	process_events
	assert(planner.success?)

	[planner.planned_task, planner]
    end
    def test_planning_loop
	task_model = Class.new(SimpleTask)
	planner_model = Class.new(Planning::Planner) do
	    @result_task = nil
	    attr_reader :result_task
	    method(:task) { @result_task = task_model.new }
	end

	plan.insert(main_task = Roby::Task.new)
	planning_task_options = {:planner_model => planner_model, :planned_model => SimpleTask, :method_name => :task, :method_options => {}}
	loop_task_options = planning_task_options.merge(:period => nil, :lookahead => 2)
	loop_planner = PlanningLoop.new(loop_task_options)
	main_task.planned_by loop_planner

	loop_planner.append_pattern
	assert_equal(1, main_task.children.to_a.size)
	first_task = main_task.children.find { true }
	assert_equal(SimpleTask, first_task.class)
	first_planner = first_task.planning_task
	assert_equal(planning_task_options, first_task.planning_task.arguments)
	assert_equal(1, loop_planner.patterns.size)

	loop_planner.append_pattern
	assert_equal(2, main_task.children.to_a.size)
	second_task = main_task.children.find { |t| t != first_task }
	assert_equal(SimpleTask, first_task.class)
	second_planner = second_task.planning_task
	assert_equal(planning_task_options, first_task.planning_task.arguments)
	assert_equal(2, loop_planner.patterns.size)

	assert_not_same(first_planner, second_planner)

	loop_planner.emit(:start) # bypass the command
	
	# Plan the first two patterns (lookahead == 2)
	first_planner.start!
	first_planner.thread.join
	process_events

	assert(first_planner.success?)
	assert(second_planner.running?)

	first_task = first_planner.planned_task
	assert(!first_task.running? && !second_task.running?)
	assert_equal(2, loop_planner.patterns.size)

	second_planner.thread.join
	process_events
	assert(second_planner.success?)
	second_task = second_planner.planned_task
	assert(!first_task.running? && !second_task.running?)
	assert_equal(2, loop_planner.patterns.size)

	# Start the first pattern, check we have one more planner and that it
	# is running to keep the lookahead
	loop_planner.loop_start!
	assert(first_task.running? && !second_task.running?)
	assert_equal(3, main_task.children.to_a.size)
	third_task = (main_task.children.to_value_set - [first_task, second_task].to_value_set).to_a.first
	third_planner = third_task.planning_task
	assert(third_planner.running?)

	# Stop the first task and call loop_start! again. The second task
	# should be running, and a fourth planner added and not running
	first_task.success!
	assert(!second_task.running?)

	loop_planner.loop_start!
	assert(first_task.success? && second_task.running?)
	fourth_task = (main_task.children.to_value_set - [first_task, second_task, third_task].to_value_set).to_a.first
	fourth_planner = fourth_task.planning_task
	assert(!fourth_planner.running?)

	# Finish the second task before making the third planner finish
	second_task.success!

	loop_planner.loop_start!
	# Finish third planning, check that both the third task and fourth planning are started
	third_planner.thread.join
	process_events
	assert(third_planner.success?)
	third_task = third_planner.planned_task
	assert(third_task.running?)
	assert(fourth_planner.running?)
    end

    def test_planning_loop_start
	task_model = Class.new(SimpleTask)
	planner_model = Class.new(Planning::Planner) { method(:task) { task_model.new } }

	plan.insert(main_task = Roby::Task.new)
	loop_planner = PlanningLoop.new :period => nil, :lookahead => 2, 
	    :planner_model => planner_model, :planned_model => SimpleTask, 
	    :method_name => :task, :method_options => {}	
	main_task.planned_by loop_planner

	loop_planner.start!
	assert_equal(2, main_task.children.to_a.size)
	assert(first_task = main_task.children.find { |t| t.planning_task.running? })
    end

    def test_planning_loop_periodic
	task_model = Class.new(SimpleTask)
	planner_model = Class.new(Planning::Planner) do 
	    method(:task) { task_model.new }
	end

	plan.insert(main_task = Roby::Task.new)
	loop_planner = PlanningLoop.new :period => 0.5, :lookahead => 2, 
	    :planner_model => planner_model, :planned_model => Roby::Task, 
	    :method_name => :task, :method_options => {}	
	main_task.planned_by loop_planner

	loop_planner.start!
	first_task, first_planner = planning_loop_next(main_task)
	second_task, second_planner = planning_loop_next(main_task)

	loop_planner.loop_start!
	# Get the third planner *NOW*... We will call process_events and it will be
	# harder to get it later
	third_task, third_planner = planning_loop_next(main_task)

	assert(first_task.running?)
	assert(!second_task.running?)
	first_task.success!
	assert(!first_task.running? && !second_task.running?)
	process_events
	assert(!second_task.running?)
	assert_happens do
	    assert(second_task.running?)
	end

	# Check that the timeout can be overriden by calling loop_start! on the PlanningLoop
	# task
	assert(third_planner.success?)
	third_task = third_planner.planned_task

	assert(second_task.running? && !third_task.running?)
	second_task.success!
	assert(!second_task.running? && !third_task.running?)
	process_events
	assert(!third_task.running?)
	loop_planner.loop_start!
	assert(third_task.running?, third_task.object_id)
    end

    def test_planning_loop_zero_lookahead
	task_model = Class.new(SimpleTask)

	id = 0
	planner_model = Class.new(Planning::Planner) do 
	    method(:task) do 
		task_model.new(arguments[:context])
	    end
	end

	plan.insert(main_task = Roby::Task.new)
	loop_planner = PlanningLoop.new :period => 0.5, :lookahead => 0, 
	    :planner_model => planner_model, :planned_model => Roby::Task, 
	    :method_name => :task, :method_options => {}	
	main_task.planned_by loop_planner

	loop_planner.start!
	assert(!main_task.children.find { |t| t.planning_task.running? })
	loop_planner.loop_start!(:id => 1)

	first_task, first_planner = planning_loop_next(main_task)
	assert_equal(1, first_task.arguments[:id])

	assert_equal(1, main_task.children.to_a.size)
	loop_planner.loop_start!(:id => 2)
	loop_planner.loop_start!(:id => 3)
	assert_equal(3, main_task.children.to_a.size)
	second_task, second_planner = planning_loop_next(main_task)
	assert_equal(2, second_task.arguments[:id])
	third_task, third_planner = planning_loop_next(main_task)
	assert_equal(3, third_task.arguments[:id])

	assert(first_task.running?)
	assert(!second_task.running?)
	assert(!third_task.running?)
	first_task.success!
	assert_equal(2, main_task.children.to_a.size)
	assert(!first_task.running?)
	assert(second_task.running?)
	assert(!third_task.running?)
	second_task.success!
	assert_equal(1, main_task.children.to_a.size)
	assert(!second_task.running?)
	assert(third_task.running?)
	third_task.success!
	assert_equal(1, main_task.children.to_a.size)
	assert(!third_task.running?)
    end

    def test_planning_loop_reinit_periodic
	task_model = Class.new(SimpleTask)
	planner_model = Class.new(Planning::Planner) do 
	    @@id = 0
	    method(:task) do 
		task_model.new(:id => (@@id += 1))
	    end
	end

	plan.insert(main_task = Roby::Task.new)
	loop_planner = PlanningLoop.new :period => 0, :lookahead => 1, 
	    :planner_model => planner_model, :planned_model => Roby::Task, 
	    :method_name => :task, :method_options => {}	
	main_task.planned_by loop_planner

	FlexMock.use do |mock|
	    mock.should_receive(:started).twice
	    task_model.on(:start) { mock.started }

	    loop_planner.start!
	    first_task, first_planner   = planning_loop_next(main_task)

	    loop_planner.loop_start!
	    assert(first_task.running?)

	    # Wait for the first pattern to be started, and then call reinit
	    loop_planner.reinit
	    old_first  = first_task
	    assert_equal(first_planner, loop_planner.patterns.last.first)
	    # Make sure the old task is GCed
	    first_task, first_planner = planning_loop_next(main_task)
	    assert_event(old_first.event(:stop))
	    assert(!old_first.plan)
	    assert(first_planner.finished?)
	    assert_not_equal(first_task, old_first)
	    process_events
	    assert(first_task.running?, first_task)
	end
    end

    def test_planning_loop_reinit_zero_lookahead
	task_model = Class.new(SimpleTask)
	planner_model = Class.new(Planning::Planner) do 
	    @@id = 0
	    method(:task) do 
		task_model.new(:id => (@@id += 1))
	    end
	end

	plan.insert(main_task = Roby::Task.new)
	loop_planner = PlanningLoop.new :period => nil, :lookahead => 0, 
	    :planner_model => planner_model, :planned_model => Roby::Task, 
	    :method_name => :task, :method_options => {}	
	main_task.planned_by loop_planner


	FlexMock.use do |mock|
	    mock.should_receive(:started).twice
	    task_model.on(:start) { mock.started }

	    loop_planner.start!
	    loop_planner.loop_start!
	    first_task, first_planner = planning_loop_next(main_task)
	    assert(first_task.running?)

	    loop_planner.reinit
	    loop_planner.loop_start!
	    old_first = first_task
	    first_task, first_planner   = planning_loop_next(main_task)
	    assert_equal(2, first_task.arguments[:id])

	    assert(old_first.running?)
	    assert(first_task.pending?)

	    process_events
	    assert(old_first.finished?)
	    assert(first_task.running?)
	end
    end

    def test_make_loop
	planner_model = Class.new(Planning::Planner) do
	    include Test::Unit::Assertions

	    @result_task = nil
	    attr_reader :result_task
	    method(:task) {  @result_task = SimpleTask.new(:id => arguments[:task_id])}
	    method(:looping_tasks) do
		t1 = make_loop(:period => 0, :child_argument => 2) do
		    # arguments of 'my_looping_task' shall be forwarded
		    raise unless arguments[:parent_argument] == 1
		    raise unless arguments[:child_argument] == 2
		    task(:task_id => 'first_loop')
		end
		t2 = make_loop do
		    task(:task_id => 'second_loop')
		end
		# Make sure the two loops are different
		assert(t1.method_options[:id] != t2.method_options[:id])
		[t1, t2]
	    end
	end

	planner = planner_model.new(plan)
	t1, t2 = planner.looping_tasks(:parent_argument => 1)
	plan.insert(t1)
	plan.insert(t2)

	t1.start!
	assert_event(t1.last_planning_task.event(:success))
	planned_task = t1.children.find { true }
	assert_equal('first_loop', planned_task.arguments[:id])

	t2.start!
	assert_event(t2.last_planning_task.event(:success))
	planned_task = t2.children.find { true }
	assert_equal('second_loop', planned_task.arguments[:id])

	t3 = planner.make_loop(:period => 0, :parent_argument => 1, :child_argument => 2) do
	    task(:task_id => 'third_loop')
	end
	plan.insert(t3)
	t3.start!
	assert_equal('third_loop', planning_task_result(t3.last_planning_task).arguments[:id])

	# Now, make sure unneccessary methods are created
	name1, id1 = t1.method_name, t1.method_options[:id]
	name2, id2 = t2.method_name, t2.method_options[:id]
	t1, t2 = planner.looping_tasks(:parent_argument => 1)
	assert_equal(name1, t1.method_name)
	assert_equal(name2, t2.method_name)
	assert_equal(id1, t1.method_options[:id])
	assert_equal(id2, t2.method_options[:id])
    end

    def planning_task_result(task)
	plan.insert(task)
	task.start! if task.pending?
	assert_event(task.event(:success))
	task.planned_task
    end
end

