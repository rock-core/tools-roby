$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/interface'
require 'flexmock'

class TC_Interface < Test::Unit::TestCase 
    include Roby::Test

    def setup
        super
        Roby.app.filter_backtraces = false
    end


    include Roby::Planning
    def test_method_missing
        iface   = Interface.new(engine)

        task_model = Class.new(Task)

        result_task = nil
        planner = Class.new(Planner) do
            method(:null_task) { result_task = task_model.new }
        end
        Roby.app.planners << planner

	engine.run
	returned_task = iface.null_task!
        engine.wait_until(returned_task.planning_task.stop_event) do
            returned_task.planning_task.start!
        end
        assert result_task

	assert_kind_of(Roby::RemoteObjectProxy, returned_task)
	marshalled = nil
	assert_nothing_raised { marshalled = Marshal.dump(returned_task) }
	unmarshalled = Marshal.load(marshalled)

	assert_kind_of(Roby::PlanService, unmarshalled)
	assert_equal(result_task, unmarshalled.task)
	plan_task = plan.missions.find { true }
	assert_equal(plan_task, unmarshalled.task)
    end
end

