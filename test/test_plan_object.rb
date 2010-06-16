$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/empty_task'
require 'flexmock'

class TC_PlanObject < Test::Unit::TestCase 
    include Roby::Test
    include Roby::Test::Assertions
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
end
