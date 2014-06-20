require 'roby/test/self'

class TC_PlanObject < Minitest::Test 
    def setup
        super
        Roby.app.filter_backtraces = false
    end

    class MockupPlan
        def executable?; !!@executable end
        def initialize(exec); @executable = exec end
    end
    def test_model_finalization_handler
        mockup_plan = MockupPlan.new(true)
        FlexMock.use do |mock|
            klass = Class.new(PlanObject) do
                when_finalized do
                    mock.finalized(self)
                end
            end
            obj = klass.new
            obj.plan = mockup_plan

            mock.should_receive(:finalized).with(obj).once
            obj.finalized!
        end
    end

    def test_model_finalization_handler_on_non_executable_plan
        mockup_plan = MockupPlan.new(false)
        FlexMock.use do |mock|
            klass = Class.new(PlanObject) do
                when_finalized do
                    mock.finalized(self)
                end
            end
            obj = klass.new
            obj.plan = mockup_plan
            obj.when_finalized do
                mock.finalized
            end

            mock.should_receive(:finalized).with(obj).never
            obj.finalized!
        end
    end

    def test_finalization_handler
        mockup_plan = MockupPlan.new(true)
        obj = PlanObject.new
        obj.plan = mockup_plan

        FlexMock.use do |mock|
            obj.when_finalized do
                mock.finalized
            end
            mock.should_receive(:finalized).once
            obj.finalized!
        end
    end

    def test_plan_synchronization
        klass = Class.new(PlanObject)
	space = Roby::RelationSpace(klass)
        relation = space.relation :R

        plan = Roby::Plan.new
        parent = klass.new
        child = klass.new
        parent.plan = plan
        flexmock(plan).should_receive(:add).with(child).once
        parent.add_r(child)

        plan = Roby::Plan.new
        parent = klass.new
        child = klass.new
        child.plan = plan
        flexmock(plan).should_receive(:add).with(parent).once
        child.add_r(parent)
    end
end

