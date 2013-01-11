$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/tasks/simple'
require 'flexmock/test_unit'

require 'roby'
class TC_Robot < Test::Unit::TestCase
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

    def test_action_from_model_no_match
        task_m = Class.new(Roby::Task)
        planner = flexmock
        planner.should_receive(:find_all_actions_by_type).once.
            with(task_m).and_return([])
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_raises(ArgumentError) { Robot.action_from_model(task_m) }
    end
    def test_action_from_model_one_match
        task_m = Class.new(Roby::Task)
        planner = flexmock
        planner.should_receive(:find_all_actions_by_type).once.
            with(task_m).and_return([action = flexmock(:name => 'A')])
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_equal [planner, action], Robot.action_from_model(task_m)
    end
    def test_action_from_model_multiple_matches
        task_m = Class.new(Roby::Task)
        planner = flexmock
        planner.should_receive(:find_all_actions_by_type).once.
            with(task_m).and_return([flexmock(:name => 'A'), flexmock(:name => 'A')])
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_raises(ArgumentError) { Robot.action_from_model(task_m) }
    end
end

