$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'

class TC_Interface < Test::Unit::TestCase 
    include Roby::Test

    include Roby::Planning
    def test_method_missing
        control = Roby.control
        iface   = Interface.new(control)

        task_model = Class.new(Task)

        result_task = nil
        planner = Class.new(Planner) do
            method(:null_task) { result_task = task_model.new }
        end
        control.planners << planner

	control.run :detach => true
	returned_task = iface.null_task!

	plan_task = plan.missions.find { true }
	assert_equal(returned_task, result_task)
        assert_equal(plan_task, result_task)
    end
end

