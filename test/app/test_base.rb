require 'roby/test/self'

module Roby
    describe App do
        describe ".resolve_robot_in_path" do
            it "leaves paths without the ROBOT keyword alone" do
                assert_equal "/a/complete/path", Roby::App.resolve_robot_in_path("/a/complete/path", 'test')
            end
            it "removes a ROBOT entry if the robot name is the default robot name" do
                assert_equal "/a/complete/path", Roby::App.resolve_robot_in_path("/a/complete/ROBOT/path", 'default')
            end
            it "replaces a ROBOT entry by the robot name if the robot name is not the default robot name" do
                assert_equal "/a/complete/test/path", Roby::App.resolve_robot_in_path("/a/complete/ROBOT/path", 'test')
            end
        end
    end
end

