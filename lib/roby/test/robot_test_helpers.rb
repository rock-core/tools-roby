# frozen_string_literal: true

module Roby
    module Test
        # Helpers to test robot configuration functionality
        module RobotTestHelpers
            # Execute the robot controller blocks
            def execute_robot_controller
                expect_execution { app.run_controller_blocks }.to_run
            end
        end
    end
end
