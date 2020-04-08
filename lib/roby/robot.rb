# frozen_string_literal: true

require "utilrb/logger"

module Robot
    def self.log_formatter(severity, time, progname, msg)
        Roby.app.notify(progname, severity.to_s, msg)
        Roby.logger.formatter.call(severity, time, progname, msg)
    end
    extend Logger::Root("Robot", Logger::INFO, &method(:log_formatter))

    # @deprecated use Roby.app.action_from_model instead
    def self.action_from_model(model)
        Roby.app.action_from_model(model)
    end

    # @deprecated use Roby.app.find_action_from_name instead
    def self.find_action_from_name(name)
        Roby.app.find_action_from_name(name)
    end

    # @deprecated use Roby.app.action_from_name instead
    def self.action_from_name(name)
        Roby.app.action_from_name(name)
    end

    # @deprecated use Roby.app.prepare_action instead
    def self.prepare_action(plan, name, **arguments)
        if plan != Roby.app.plan
            raise ArgumentError, "cannot call prepare_action with any other plan than Roby.app.plan"
        end

        Roby.app.prepare_action(name, **arguments)
    end

    # Implements that one can call
    #
    #   Robot.action_name! arg0: value0, arg1: value1
    #
    # To inject a given action in Roby.plan. The added action is added as a
    # mission.
    #
    # See also Robot.prepare_action
    def self.method_missing(name, *args)
        if name.to_s =~ /!$/
            name = $`.to_sym
        else
            super
        end

        if args.size > 1
            raise ArgumentError, "wrong number of arguments (#{args.size} for 1) in #{name}!"
        end

        options = args.first || {}
        task, planner = Roby.app.prepare_action(name, job_id: Roby::Interface::Job.allocate_job_id, **options)
        task.plan.add_mission_task(task)
        [task, planner]
    end

    # Declare the robot type of the robot configuration being loaded
    #
    # Place this on top of the robot file in config/robots/
    def self.robot_type(robot_type)
        # Declare it first
        Roby.app.robots.declare_robot_type(Roby.app.robot_name, robot_type)
        # And then set it up
        Roby.app.robot(Roby.app.robot_name, robot_type)
    end

    def self.init(&block)
        Roby.app.on_init(user: true, &block)
    end

    def self.setup(&block)
        Roby.app.on_setup(user: true, &block)
    end

    def self.requires(&block)
        Roby.app.on_require(user: true, &block)
    end

    def self.clear_models(&block)
        Roby.app.on_clear_models(user: true, &block)
    end

    def self.cleanup(&block)
        Roby.app.on_cleanup(user: true, &block)
    end

    def self.config(&block)
        Roby.app.on_config(user: true, &block)
    end

    def self.controller(reset: false, &block)
        Roby.app.controller(reset: reset, user: true, &block)
    end

    def self.actions(&block)
        Roby.app.actions(user: true, &block)
    end
end
