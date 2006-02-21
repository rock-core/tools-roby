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
        end
        planner = model.new

        assert(planner.respond_to?(:root))
        assert(planner.find_methods(:root).first.name == 'root')
        assert(planner.root.null?)
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

        recursive = planner.find_methods(:recursive)
        assert_equal(1, recursive.size)
        assert(recursive.first.recursive?)

        assert_raises(NotFound) { planner.not_recursive }

        plan = nil
        assert_nothing_raised { plan = planner.recursive }
        
        assert(TaskAggregator::Sequence === plan)

        sequence = plan.enum_for(:each_child).to_a
        assert_equal(2, sequence.size)
        assert(sequence.all? { |node| PlanningTask === node })
        methods = sequence.map { |node| node.plan_method }
        assert_equal([planner.find_methods(:recursive), planner.find_methods(:root)].flatten.to_set, methods.to_set)
    end
end


