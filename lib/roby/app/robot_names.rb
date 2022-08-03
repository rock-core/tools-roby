# frozen_string_literal: true

module Roby
    module App
        # The part of the configuration related to robot declaration
        class RobotNames
            # @return [String,nil] the default robot name
            attr_reader :default_robot_name
            # @return [Hash<(String,String)>] the set of declared robots, as
            #   robot_name => robot_type
            attr_reader :robots
            # @return [Hash<String,String>] a set of aliases, i.e. short names
            #   for robots
            attr_reader :aliases

            # @return [Boolean] if true, Roby will generate an error if a
            #   non-declared robot is used. Otherwise, it will only issue a
            #   warning
            def strict?
                @strict
            end

            # Sets {#strict?}
            #
            # @see strict?
            attr_writer :strict

            # Create a RobotConfiguration object based on a hash formatted as-is
            # from the app.yml file
            def initialize(options = {})
                @robots = { "default" => "default" }
                @default_robot_name = "default"
                @aliases = {}
                @strict = false

                load_config_yaml(options)
            end

            def load_config_yaml(options)
                @robots = options["robots"] || @robots
                @strict = !!options["robots"]

                @default_robot_name = options["default_robot"] || @default_robot_name
                unless has_robot?(default_robot_name)
                    robots[default_robot_name] = default_robot_name
                end

                @aliases = options["aliases"] || @aliases
                aliases.each do |name_alias, name|
                    unless has_robot?(name)
                        raise ArgumentError,
                              "cannot use #{name_alias} as an alias to #{name}: "\
                              "#{name} is not a declared robot"
                    end
                    if has_robot?(name_alias)
                        raise ArgumentError,
                              "cannot use #{name_alias} as an alias to #{name}: "\
                              "#{name_alias} is already a declared robot"
                    end
                end
            end

            # Declare the type of an existing robot
            def declare_robot_type(robot_name, robot_type)
                if strict? && !has_robot?(robot_type)
                    raise ArgumentError, "#{robot_type} is not a known robot"
                end

                robots[robot_name] = robot_type
            end

            # Enumerate the robot names and types
            def each(&block)
                robots.each(&block)
            end

            # Enumerate the list of known robots
            #
            # @yieldparam [String] robot_name the robot name
            def names
                robots.keys
            end

            # @return [String,nil] the type of the default robot
            def default_robot_type
                if default_robot_name
                    robots[default_robot_name]
                end
            end

            # Tests whether the given name is a declared robot
            #
            # @return [Boolean]
            def has_robot?(name, type = nil)
                robots.has_key?(name.to_s) &&
                    (!type || robots[name.to_s] == type.to_s)
            end

            # Helper method which either warns or raises depending on the
            # value of {#strict?}
            def error(klass, message)
                if strict?
                    raise klass, message
                else
                    Roby::Application.warn message
                end
            end

            # Returns the robot name and type matching the given name
            #
            # It resolves aliases
            #
            # @param [String] name a robot name or alias
            # @return [(String,String)]
            # @raise ArgumentError if the given robot name does not exist
            def resolve(name, type = nil)
                robot_name = aliases[name] || name || default_robot_name
                if !robot_name
                    error(
                        ArgumentError,
                        "no robot name given and no default name declared in "\
                        "app.yml, defaulting to #{default_robot_name}:"\
                        "#{default_robot_type}"
                    )
                    [default_robot_name, default_robot_type]
                elsif robots.has_key?(robot_name)
                    robot_type = robots[robot_name]
                    type ||= robot_type
                    if type != robot_type
                        error(
                            ArgumentError,
                            "invalid robot type when resolving #{name}:#{type}, "\
                            "#{name} is declared to be of type #{robot_type}"
                        )
                    end
                    [robot_name, type]
                else
                    if !robots.empty? || strict?
                        error(
                            Application::NoSuchRobot,
                            "#{name} is neither a robot name, nor an alias. "\
                            "Known names: #{robots.keys.sort.join(', ')}, "\
                            "known aliases: #{aliases.keys.join(', ')}"
                        )
                    end
                    [robot_name, (type || robot_name)]
                end
            end
        end
    end
end
