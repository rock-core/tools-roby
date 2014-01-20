module Roby
    module App
        DEFAULT_ROBOT_NAME = 'default'
        DEFAULT_ROBOT_TYPE = 'default'

        # Resolves the ROBOT keyword in the given path
        #
        # @param [String] path
        # @param [String] robot_name
        # @return [String]
        def self.resolve_robot_in_path(path, robot_name = Roby.app.robot_name)
            if robot_name == DEFAULT_ROBOT_NAME
                robot_name = ""
            end
            robot_name ||= ""

            path.gsub(/ROBOT/, robot_name).
                gsub(/\/\//, '/')
        end
    end
end
