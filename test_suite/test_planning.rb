require 'test/unit'
require 'test_config'
require 'pp'
require 'roby/planning'
require 'roby/relations/planned_by'

class TC_Planner < Test::Unit::TestCase
    include Roby
    include Roby::Planning

    def test_id_validation
	assert_equal(15, Planner.validate_method_id("15"))
	assert_equal('foo', Planner.validate_method_id(:foo))
	assert_equal('foo', Planner.validate_method_id('foo'))
    end

    def test_method_definition
        model = Class.new(Planner) do 
	    method(:root)
            method(:root) {}
            method(:root, :id => "15") {}
            method(:root, :id => :foobar) {}
            method(:root, :id => 'barfoo') {}
            method(:recursive, :recursive => true) {}
        end
	assert_equal(17, model.next_id)
	
	assert(model.respond_to?(:root_methods))
	assert(model.respond_to?(:each_root_method), model.methods.find_all { |name| name =~ /root/ }.inspect)
	assert_equal(4, model.enum_for(:each_root_method).to_a.size)
	assert(model.root_methods[1])

	assert(model.respond_to?(:root_model))

	assert(model.find_methods(:root))
	assert_equal(4, model.find_methods(:root).size)
	assert(model.find_methods(:root, :id => 1))
	assert_equal(1, model.find_methods(:root, :id => 1).size)
	assert(model.find_methods(:root, :id => 15)) # Check handling of the string -> integer convertion
	assert_equal(1, model.find_methods(:root, :id => 15).size)
	assert(model.find_methods(:root, :id => 15)) # Check handling of the symbol -> string convertion
	assert_equal(1, model.find_methods(:root, :id => 'foobar').size)
	assert_equal(1, model.find_methods(:root, :id => :barfoo).size)

	assert_equal(nil, model.find_methods('recursive', :recursive => false))
	assert_equal(1, model.find_methods('recursive', :recursive => true).size)

        planner = model.new
        assert(planner.respond_to?(:root))
        assert(planner.root.null?)
        assert(planner.respond_to?(:recursive))
	assert_raises(Planning::NotFound) { planner.recursive(:recursive => false) }
    end

    def test_recursive
        model = Class.new(Planner) do
            method(:not_recursive) do
                root
            end
            method(:recursive, :recursive => true) do
                root
            end
            method(:root, :recursive => true) do
                recursive + not_recursive
            end
        end
        planner = model.new
        assert(planner.has_method?(:recursive))
        assert(planner.respond_to?(:recursive))

        recursive = planner.class.find_methods(:recursive)
        assert_equal(1, recursive.size)
        assert(recursive.first.recursive?)

        assert_raises(NotFound) { planner.not_recursive }

        plan = nil
        assert_nothing_raised { plan = planner.plan(:recursive) }
        assert_nothing_raised { plan = planner.recursive }
        
        sequence = plan.enum_for(:each_task).to_a
        assert_equal(2, sequence.size)
        assert(sequence.all? { |node| PlanningTask === node })
        methods = sequence.map { |node| node.plan_method }
        assert_equal(['recursive', 'root'].to_set, methods.to_set)
    end

    def test_method_model
	# Some task models
        base_task_model		= Class.new(Roby::Task) do
            event :start
            event :stop
        end
        derived_task_model	= Class.new(base_task_model)
        not_a_task		= Class.new
        another_kind_of_task	= Class.new(Roby::Task)

	# The planning model
        model = Class.new(Planner)
	
	# Check method model validation
	assert_raises(ArgumentError) { model.method(:root, :returns => not_a_task) }
	model.method(:root, :returns => base_task_model)
	assert_equal( model.root_model, model.method_model(:root) )
	assert( model.method_model(:root).returns == base_task_model, model.method_model(:root).inspect )
	assert_raises(ArgumentError) { model.method(:root, :returns => another_kind_of_task) }
	assert_nothing_raised { model.method(:root, :returns => base_task_model) }

	# Define a method based on the model
	model.method(:root, :id => 1) {}
	assert_raises(ArgumentError) { model.method(:root, :returns => not_a_task) {} }
	assert_nothing_raised { model.method(:root, :returns => base_task_model) {} }
	assert_nothing_raised { model.method(:root, :returns => derived_task_model) {} }

	# Check that we can't override an already-defined method
	assert_raises(ArgumentError) { model.method(:root, :id => 1) {} }
    end

    def test_model_inheritance
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

	# Test inheritance rules
        d1 = Class.new(base)
	assert_raises(ArgumentError)	{ d1.method(:root, :returns => tm_a_a) }
	assert_raises(ArgumentError)	{ d1.method(:root, :returns => tm_b) }
	assert_raises(ArgumentError)	{ d1.method(:root, :returns => tm_b) {} }

	d1_root = []
	assert_nothing_raised { d1_root << d1.method(:root, :returns => tm_a) {} }
	assert_nothing_raised { d1_root << d1.method(:root, :returns => tm_a_a) {} }
	assert_nothing_raised { d1_root << d1.method(:root, :returns => tm_b_a) {} }
	d2_root = d1_root.dup
	assert_nothing_raised { d1_root << d1.method(:root, :id => 1, :returns => tm_a_a) {} }

	d2 = Class.new(d1)
	assert_nothing_raised { d2_root << d2.method(:root, :id => 1, :returns => tm_a_a_a) {} }

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
    end
end


