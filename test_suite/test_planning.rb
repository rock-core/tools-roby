require 'test/unit'
require 'test_config'
require 'pp'
require 'roby/planning'
require 'roby/relations/planned_by'

class TC_Planner < Test::Unit::TestCase
    include Roby
    include Roby::Planning

    def test_method_definition
	assert(!Planner.respond_to?(:root_methods))
        model = Class.new(Planner) do 
	    method(:root)
            method(:root) {}
            method(:root, :id => 15) {}
            method(:recursive, :recursive => true) {}
        end
	assert_equal(17, model.next_id)
	
	assert(model.respond_to?(:root_methods))
	assert(model.respond_to?(:each_root_method), model.methods.find_all { |name| name =~ /root/ }.inspect)
	assert_equal(2, model.enum_for(:each_root_method).to_a.size)
	assert(model.root_methods[1])

	assert(model.respond_to?(:root_model))

	assert(model.find_methods(:root))
	assert_equal(2, model.find_methods(:root).size)
	assert(model.find_methods(:root, :id => 1))
	assert_equal(1, model.find_methods(:root, :id => 1).size)
	assert(model.find_methods(:root, :id => 15))
	assert_equal(1, model.find_methods(:root, :id => 15).size)
	assert_equal(nil, model.find_methods('recursive', :recursive => false))
	assert_equal(1, model.find_methods('recursive', :recursive => true).size)

        planner = model.new
        assert(planner.respond_to?(:root))
        assert(planner.root.null?)
        assert(planner.respond_to?(:recursive))
	assert_raises(Planning::NotFound) { planner.recursive(:recursive => false) }
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
        model = Class.new(Planner) do
            method(:root, :returns => base_task_model)
            method(:root, :id => 1) {}
	    method(:root, :id => 10) {}
	    method(:root) {}
	end

	assert( model.method_model(:root) )
	assert( model.method_model(:root).returns == base_task_model, model.method_model(:root).inspect )

	# Check that :returns is correctly validated
	assert_raises(ArgumentError) { model.method(:root, :returns => not_a_task) }
	assert_raises(ArgumentError) { model.method(:root, :returns => another_kind_of_task) }

	# We cannot change the model since a method has been defined
	assert_raises(ArgumentError) { model.method(:root, :returns => derived_task_model) }
	assert_nothing_raised { model.method(:root, :returns => base_task_model) {} }
	assert_nothing_raised { model.method(:root, :returns => derived_task_model) {} }

	# Check that we can't override an already-defined method
	assert_raises(ArgumentError) { model.method(:root, :id => 1) {} }
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
        
        assert(TaskAggregator::Sequence === plan)

        sequence = plan.enum_for(:each_child).to_a
        assert_equal(2, sequence.size)
        assert(sequence.all? { |node| PlanningTask === node })
        methods = sequence.map { |node| node.plan_method }
        assert_equal(['recursive', 'root'].to_set, methods.to_set)
    end

    def test_model_inheritance
        base_task_model			= Class.new(Roby::Task)
        derived_task_model		= Class.new(base_task_model)
        another_derived_task_model	= Class.new(base_task_model)
        not_a_task			= Class.new
        another_kind_of_task		= Class.new(Roby::Task)

        base = Class.new(Planner) do
            method(:root, :returns => base_task_model)
            method(:root, :id => 1, :returns => derived_task_model) {}
	end

	# Test inheritance rules
        derived = Class.new(base)
	assert_raises(ArgumentError)	{ derived.method(:root, :returns => another_kind_of_task) }
	assert_raises(ArgumentError)	{ derived.method(:root, :returns => another_kind_of_task) {} }
	assert_nothing_raised		{ derived.method(:root, :returns => another_derived_task_model) {} }
	assert_nothing_raised		{ derived.method(:root, :returns => derived_task_model) {} }
	assert_nothing_raised		{ derived.method(:root, :returns => base_task_model) {} }
	assert_raises(ArgumentError)    { derived.method(:root, :id => 1, :returns => another_derived_task_model) {} }

	derived = Class.new(base)
	assert_raises(ArgumentError)	{ derived.method(:root, :returns => derived_task_model) }
	assert_nothing_raised		{ derived.method(:root, :returns => derived_task_model) {} }

	derived = Class.new(base)
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


