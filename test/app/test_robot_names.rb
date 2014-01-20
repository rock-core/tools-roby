$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/self'

describe Roby::App::RobotNames do
    include Roby::SelfTest

    describe "#initialize" do
        it "should get the robot list from the 'robots' field" do
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'])
            assert_equal Hash['a' => 'b'], conf.robots
        end

        it "should get the default robot name from the 'default_robot' field" do
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'], 'default_robot' => 'a')
            assert_equal 'a', conf.default_robot_name
        end

        it "should get the alias list from the 'aliases' field" do
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'], 'aliases' => Hash['X' => 'a'])
            assert_equal Hash['X' => 'a'], conf.aliases
        end

        it "should leave strict to false if there are no robots defined" do
            conf = Roby::App::RobotNames.new
            assert !conf.strict?
        end

        it "should set strict to true if there are robots defined" do
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'])
            assert conf.strict?
        end

        it "should declare the default robot if it is not already the case" do
            conf = Roby::App::RobotNames.new('default_robot' => 'a')
            assert_equal 'a', conf.robots['a']
        end

        it "should raise if the name being aliased is not defined" do
            assert_raises(ArgumentError) { Roby::App::RobotNames.new('aliases' => Hash['a' => 'b']) }
        end

        it "should raise if the new name in an alias is already a robot name" do
            assert_raises(ArgumentError) { Roby::App::RobotNames.new('robots' => Hash['b' => 'b', 'a' => 'a'],
                                                                             'aliases' => Hash['a' => 'b']) }
        end
    end

    describe "#default_robot_type" do
        it "should return the robot type from default_robot_name using the robots field" do
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'],
                                                     'default_robot' => 'a')
            assert_equal 'b', conf.default_robot_type
        end
        it "should return nil if no default robot is defined" do
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'])
            assert !conf.default_robot_type
        end
    end

    describe "#resolve" do
        it "should return the robot name and type if given a valid robot name" do
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'])
            assert_equal ['a', 'b'], conf.resolve('a')
        end
        it "should return the robot name and type if given a proper alias" do
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'], 'aliases' => Hash['X' => 'a'])
            assert_equal ['a', 'b'], conf.resolve('X')
        end
        it "should raise if given an unknown name and strict is set" do
            conf = Roby::App::RobotNames.new
            conf.strict = true
            assert_raises(ArgumentError) { conf.resolve('bla') }
        end
        it "should raise when given a known name and an invalid type if strict is set" do
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'])
            conf.strict = true
            assert_raises(ArgumentError) { conf.resolve('a', 'X') }
        end
        it "should return the given name and type and warn when given an invalid name and an invalid type if strict is not set" do
            flexmock(Roby::Application).should_receive(:warn).once
            conf = Roby::App::RobotNames.new
            conf.strict = false
            assert_equal ['a', 'X'], conf.resolve('a', 'X')
        end
        it "should return the given name for both robot name and robot type, and warn, when given an invalid name if strict is not set" do
            flexmock(Roby::Application).should_receive(:warn).once
            conf = Roby::App::RobotNames.new
            conf.strict = false
            assert_equal ['a', 'a'], conf.resolve('a')
        end
        it "should return the given type and warn when given a known name and an invalid type if strict is not set" do
            flexmock(Roby::Application).should_receive(:warn).once
            conf = Roby::App::RobotNames.new('robots' => Hash['a' => 'b'])
            conf.strict = false
            assert_equal ['a', 'X'], conf.resolve('a', 'X')
        end
    end
end

