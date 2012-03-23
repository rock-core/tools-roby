$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/tasks/simple'
require 'flexmock/test_unit'

require 'roby'
class TC_Robot < Test::Unit::TestCase
    include Roby::Test
    include Roby::Test::Assertions

    def test_action_from_model_no_match
        task_t = Class.new(Roby::Task)

        planner = flexmock
        planner.should_expect do |pl|
            pl.planning_methods_names.and_return(%w{m1 m2 m3})
            pl.find_methods("m1", :returns => task_t).once.and_return(nil)
            pl.find_methods("m2", :returns => task_t).once.and_return(nil)
            pl.find_methods("m3", :returns => task_t).once.and_return(nil)
        end
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_raises(ArgumentError) { Robot.action_from_model(task_t) }
    end

    def test_action_from_model_single_match
        task_t = Class.new(Roby::Task)

        m2 = flexmock(:name => "m2", :options => Hash.new)
        planner = flexmock
        planner.should_expect do |pl|
            pl.planning_methods_names.and_return(%w{m1 m2 m3})
            pl.find_methods("m1", :returns => task_t).once.and_return(nil)
            pl.find_methods("m2", :returns => task_t).once.and_return([m2])
            pl.find_methods("m3", :returns => task_t).once.and_return(nil)
        end
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_equal [planner, m2], Robot.action_from_model(task_t)
    end


    def test_action_from_model_multiple_matches_same_method
        task_t = Class.new(Roby::Task)

        m2_1 = flexmock(:name => "m2_1", :options => {:id => 1}) 
        m2_2 = flexmock(:name => "m2_2", :options => {:id => 2})
        planner = flexmock
        planner.should_expect do |pl|
            pl.planning_methods_names.and_return(%w{m1 m2 m3})
            pl.find_methods("m1", :returns => task_t).once.and_return(nil)
            pl.find_methods("m2", :returns => task_t).once.and_return([m2_1, m2_2])
            pl.find_methods("m3", :returns => task_t).once.and_return(nil)
        end
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_raises(ArgumentError) { Robot.action_from_model(task_t) }
    end


    def test_action_from_model_multiple_matches_different_methods
        task_t = Class.new(Roby::Task)

        m1 = flexmock(:name => "m1", :options => Hash.new) 
        m2 = flexmock(:name => "m2", :options => {:id => 2})

        planner = flexmock
        planner.should_expect do |pl|
            pl.planning_methods_names.and_return(%w{m1 m2 m3})
            pl.find_methods("m1", :returns => task_t).once.and_return([m1])
            pl.find_methods("m2", :returns => task_t).once.and_return([m2])
            pl.find_methods("m3", :returns => task_t).once.and_return(nil)
        end
        Roby.app.planners.clear
        Roby.app.planners << planner
        assert_raises(ArgumentError) { Robot.action_from_model(task_t) }
    end
end

