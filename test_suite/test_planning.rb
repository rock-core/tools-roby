require 'test/unit'
require 'test_config'
require 'roby/planning'
require 'roby/relations/planned_by'

class TC_PlanningModel < Test::Unit::TestCase
    include Roby

    def test_support
        model = Class.new(PlanningModel) do 
            method(:root) do end
        end
        planner = model.new

        assert(planner.respond_to?(:root))
        assert(planner.method(:root).name == 'root')
        assert(planner.root.null?)
    end

    def test_recursive
        model = Class.new(PlanningModel) do
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
        assert( planner.method(:recursive).recursive? )

        assert_raises(PlanModelError) { planner.not_recursive }

        plan = nil
        assert_nothing_raised { plan = planner.recursive }
        
        assert(TaskAggregator::Sequence === plan)

        sequence = plan.enum_for(:each_child).to_a
        assert_equal(2, sequence.size)
        assert(sequence.all? { |node| PlanningTask === node })
        methods = sequence.map { |node| node.plan_method }
        assert_equal([planner.method(:recursive), planner.method(:root)].to_set, methods.to_set)
    end
end


