require 'test/unit'
require 'test_config'
require 'pp'
require 'roby/planning'
require 'roby/relations/planned_by'

class TC_Planner < Test::Unit::TestCase
    include Roby
    include Roby::Planning

    def test_support
        model = Class.new(Planner) do 
            method(:root) do end
            method(:recursive, :recursive => true) do end
        end
        planner = model.new

        assert(planner.respond_to?(:root))
        assert(planner.class.find_methods(:root).first.name == 'root')
        assert(planner.root.null?)

        assert(planner.respond_to?(:recursive))
        assert_equal(1, planner.class.find_methods(:recursive, :recursive => true).size)
        assert_equal(nil, planner.class.find_methods(:recursive, :recursive => false))
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

    def test_model
        base_task_model = Class.new(Roby::Task) do
            event :start
            event :stop
        end
        derived_task_model = Class.new(base_task_model)
        not_a_task = Class.new
        another_kind_of_task = Class.new(Roby::Task)

        base = Class.new(Planner) do
            extend Test::Unit::Assertions
            
            method(:root, :returns => base_task_model)
            assert( method_model(:root) )
            assert( method_model(:root).returns == base_task_model )

            method(:root, :id => 1) do
            end
            assert_equal(2, next_id)

            method(:root, :id => 10) do
            end
            assert_equal(11, next_id)
            method(:root) do
            end

            
            assert_raises(ArgumentError) { method(:root, :returns => not_a_task) }
            assert_raises(ArgumentError) { method(:root, :returns => another_kind_of_task) }
        end

        base_root_methods = base.find_methods(:root)
        assert_equal([], base_root_methods.find_all { |m| !(m.returns == base_task_model) } )
        assert_equal([1, 10, 12].to_set, base_root_methods.collect { |m| m.id }.to_set)

        base.class_eval do
            assert_raises(ArgumentError) { method(:root, :returns => derived_task_model) }
            assert_nothing_raised { method(:root, :returns => base_task_model) {} }
        end

        derived = Class.new(base) do
            assert_raises(ArgumentError) { method(:root, :returns => another_kind_of_task) }
            assert_nothing_raised { method(:root, :returns => derived_task_model) }
            assert( method_model(:root).returns == derived_task_model )
            assert_raises(ArgumentError) { method(:root, :returns => base_task_model) {} }
            assert_nothing_raised { method(:root, :returns => derived_task_model) {} }
        end
    end
end


