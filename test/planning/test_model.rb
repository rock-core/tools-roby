$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/planning'

require 'flexmock/test_unit'
require 'roby/tasks/simple'
require 'roby/tasks/null'

class TC_Planner < Test::Unit::TestCase
    include Roby::Planning
    include Roby::SelfTest

    NullTask = Roby::Tasks::Null

    def test_id_validation
	assert_equal(15, Planner.validate_method_id("15"))
	assert_equal('foo', Planner.validate_method_id(:foo))
	assert_equal('foo', Planner.validate_method_id('foo'))
    end

    def test_default_method_description_has_name_set
        planner = Class.new(Planner) { method :test_method }
        assert_equal 'test_method', planner.find_action_by_name(:test_method).name
        planner = Class.new(Planner) { method(:test_method) { } }
        assert_equal 'test_method', planner.find_action_by_name(:test_method).name
    end

    def test_explicit_method_description_has_name_set
        planner = Class.new(Planner) do
            describe "this is the test method"
            method :test_method
        end
        assert_equal 'test_method', planner.find_action_by_name(:test_method).name
        planner = Class.new(Planner) do
            describe "this is the test method"
            method(:test_method) { }
        end
        assert_equal 'test_method', planner.find_action_by_name(:test_method).name
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

    def test_find_methods_by_return_value
        task_t = Roby::Task.new_submodel
        other_task_t = Roby::Task.new_submodel
        subtask_t = task_t.new_submodel

        method_model = nil
        m = []
        model = Class.new(Planner) do 
	    method_model = method(:m1)
	    m << method(:m1) { NullTask.new }
	    m << method(:m1, :returns => task_t) { NullTask.new }
	    m << method(:m1, :returns => other_task_t) { NullTask.new }
	    m << method(:m1, :returns => subtask_t) { NullTask.new }
        end

        assert_equal(m.to_set, model.find_methods("m1").to_set)
        assert_equal([m[1], m[3]].to_set, model.find_methods("m1", :returns => task_t).to_set)
        assert_equal([m[2]], model.find_methods("m1", :returns => other_task_t))
        assert_equal([m[3]], model.find_methods("m1", :returns => subtask_t))
    end

    def test_returned_type_from_specific_method_is_inherited_from_method_model
        task_model = Roby::Task.new_submodel
	planner_model = Class.new(Planner) do
	    method(:m, :returns => task_model)
            method(:m, :id => :bla) do
            end
	end

        assert_equal task_model, planner_model.find_methods(:m).first.returned_type
    end

    def test_reuse
	task_model = Task.new_submodel
	derived_model = task_model.new_submodel
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
	task_model = Roby::Task.new_submodel
	model = Class.new(Roby::Planning::Planner) do
	    method(:empty_set, :returns => task_model)
	end

	planner = model.new(plan)
	assert_raises(NotFound) { planner.empty_set }

	plan.add_mission(task = task_model.new)
	found_task = nil
	found_task = planner.empty_set(:reuse => true)
	assert_equal(found_task, task)
	assert_raises(NotFound) { planner.empty_set :reuse => false }
    end

    def assert_result_plan_size(size, planner_model, method, options)
	planner = planner_model.new(plan)
	result = planner.send(method, options)
	result.each do |task|
	    planner.plan.add_mission(task)
	end
	assert_equal(size, planner.plan.size, planner.plan.known_tasks.to_a.inspect)

	new_plan
    end

    def test_recursive
	task_model = Roby::Task.new_submodel do
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
                    root = recursive
                    child = not_recursive
                    root.depends_on child
                    root
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
        tm_a = Roby::Task.new_submodel
        tm_a_a = tm_a.new_submodel
        tm_b = Roby::Task.new_submodel
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
        tm1 = Roby::Task.new_submodel
	tm2 = tm1.new_submodel
	tm3 = tm2.new_submodel
	base = Class.new(Planner) do
	    method(:root, :returns => tm1)
	    method(:root, :id => 'nil') { }
	    method(:root, :id => 'tm2', :returns => tm2) { }

            method :single_planning_method, :returns => tm1 do
            end
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

        assert_equal(tm1, base.model_of(:single_planning_method).returns)
    end

    def test_returns_validation
        task_model = Roby::Task.new_submodel
	task_tag   = TaskService.new_submodel

	planner_model = Class.new(Planning::Planner)
	assert_nothing_raised { planner_model.method(:returns_task, :returns => task_model) }
	assert_nothing_raised { planner_model.method(:returns_tag, :returns => task_tag) }
    end


    def test_returns_inheritance
	# Some task models
        tm_a = Roby::Task.new_submodel
        tm_a_a = tm_a.new_submodel
        tm_b = Roby::Task.new_submodel
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

    def test_doc_inheritance
        base_doc = "method_in_base_description"
        base = Class.new(Planner) do
            describe(base_doc)
            method(:method_in_base) { }
        end

        derived_doc = "method_in_derived_description"
        derived = Class.new(base) do
            describe(derived_doc)
            method(:method_in_derived) { }
        end

        assert(base.has_method?(:method_in_base))
        assert(base.planning_method_description(:method_in_base).doc == [ base_doc.to_s])
        assert(base.method_in_base_description != nil)
        assert(base.method_in_base_description.doc == [ base_doc.to_s ] )

        assert(derived.has_method?(:method_in_derived))
        assert(derived.has_method?(:method_in_base))

        assert(derived.planning_method_description(:method_in_base).doc == [ base_doc.to_s ])
        assert(derived.method_in_base_description != nil)
        assert(derived.method_in_base_description.doc == [ base_doc.to_s ] )

        assert(derived.planning_method_description(:method_in_derived).doc == [ derived_doc.to_s ])
        assert(derived.method_in_derived_description != nil)
        assert(derived.method_in_derived_description.doc == [ derived_doc.to_s ] )

        assert(derived.each_method_in_base_method.to_a.size == 1 )
        assert(derived.each_method_in_derived_method.to_a.size == 1 )
    end

    def test_method_inheritance
	# Define a few task models
        tm_a	    = Roby::Task.new_submodel
        tm_b	    = Roby::Task.new_submodel
        tm_a_a	    = tm_a.new_submodel
        tm_a_a_a    = tm_a_a.new_submodel
        tm_b_a	    = tm_a.new_submodel

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
	d1_root << d1.method(:root, :returns => tm_a) {}
	d1_root << d1.method(:root, :returns => tm_a_a) {}
	d1_root << d1.method(:root, :returns => tm_b_a) {}
	d2_root = d1_root.dup
	d1_root << d1.method(:root, :id => 1, :returns => tm_a_a) {}

	d2 = Class.new(d1)
	d2_root << d2.method(:root, :id => 1, :returns => tm_a_a_a) {}

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

	e = Module.new do
	    planning_library(:id => "e")
	    method(:test) { Roby::Test::Tasks::Simple.new }
	end
	planner = Class.new(Planner) do
	    using e
	end.new(plan)
	assert_nothing_raised { planner.test(:id => 'e') }
    end

    def test_return_type
	task_model = Task.new_submodel do
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

        assert_raises(ArgumentError) { Class.new(base).filter(:test) { |a| true } }
        assert_raises(ArgumentError) { Class.new(base).filter(:test) { |a, b, c| true } }

	planner, filter_block = nil, lambda { |a, b| true }
	assert_nothing_raised do
            planner = Class.new(base) do
                filter(:test, &filter_block)
            end
        end

	assert(planner.respond_to?(:each_test_filter))
	assert_equal([filter_block], planner.enum_for(:each_test_filter).to_a)
	assert_equal(2, planner.find_methods('test', :index => 10).size)

	planner = Class.new(base) do
	    filter(:test) { |a, b| false }
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
	    filter(:test) { |a, b| false }
	end.new(plan)
	assert_raises(Planning::NotFound) { planner.test }
    end

    def test_find_all_actions_by_type_no_match
        task_t = Roby::Task.new_submodel

        flexmock(planner = Class.new(Roby::Planning::Planner)) do |pl|
            pl.should_receive(:planning_methods_names).and_return(%w{m1 m2 m3})
            pl.should_receive(:find_methods).with("m1", :returns => task_t).once.and_return(nil)
            pl.should_receive(:find_methods).with("m2", :returns => task_t).once.and_return(nil)
            pl.should_receive(:find_methods).with("m3", :returns => task_t).once.and_return(nil)
        end
        assert_equal [], planner.find_all_actions_by_type(task_t)
    end

    def test_find_all_actions_by_type_single_match
        task_t = Roby::Task.new_submodel

        m2 = flexmock(:name => "m2", :options => Hash.new)
        flexmock(planner = Class.new(Roby::Planning::Planner)) do |pl|
            pl.should_receive(:planning_methods_names).and_return(%w{m1 m2 m3})
            pl.should_receive(:find_methods).with("m1", :returns => task_t).once.and_return(nil)
            pl.should_receive(:find_methods).with("m2", :returns => task_t).once.and_return([m2])
            pl.should_receive(:find_methods).with("m3", :returns => task_t).once.and_return(nil)
        end
        assert_equal [m2], planner.find_all_actions_by_type(task_t)
    end


    def test_find_all_actions_by_type_multiple_matches_same_method
        task_t = Roby::Task.new_submodel

        m2_1 = flexmock(:name => "m2_1", :options => {:id => 1}) 
        m2_2 = flexmock(:name => "m2_2", :options => {:id => 2})
        flexmock(:safe, planner = Class.new(Roby::Planning::Planner)) do |pl|
            pl.should_receive(:planning_methods_names).and_return(%w{m1 m2 m3})
            pl.should_receive(:find_methods).with("m1", :returns => task_t).once.and_return(nil)
            pl.should_receive(:find_methods).with("m2", :returns => task_t).once.and_return([m2_1, m2_2])
            pl.should_receive(:find_methods).with("m3", :returns => task_t).once.and_return(nil)
        end
        assert_equal [m2_1, m2_2], planner.find_all_actions_by_type(task_t)
    end

    def test_find_all_actions_by_type_multiple_matches_different_methods
        task_t = Roby::Task.new_submodel

        m1 = flexmock(:name => "m1", :options => Hash.new) 
        m2 = flexmock(:name => "m2", :options => {:id => 2})

        flexmock(planner = Class.new(Roby::Planning::Planner)) do |pl|
            pl.should_receive(:planning_methods_names).and_return(%w{m1 m2 m3})
            pl.should_receive(:find_methods).with("m1", :returns => task_t).once.and_return([m1])
            pl.should_receive(:find_methods).with("m2", :returns => task_t).once.and_return([m2])
            pl.should_receive(:find_methods).with("m3", :returns => task_t).once.and_return(nil)
        end
        assert_equal [m1, m2], planner.find_all_actions_by_type(task_t)
    end

    def test_it_does_not_allow_to_override_an_existing_normal_method_with_a_planning_method
        planner_m = Class.new(Roby::Planning::Planner)
        assert_raises(ArgumentError) { planner_m.method(:stop) }
    end

end

