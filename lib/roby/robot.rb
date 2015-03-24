require 'utilrb/logger'

module Robot
    def self.log_formatter(severity, time, progname, msg)
        Roby.app.notify(progname, severity.to_s, msg)
        Roby.logger.formatter.call(severity, time, progname, msg)
    end
    extend Logger::Root('Robot', Logger::INFO, &method(:log_formatter))

    # @deprecated use Roby.app.action_from_model instead
    def self.action_from_model(model)
        return Roby.app.action_from_model(model)
    end
    
    # @deprecated use Roby.app.find_action_from_name instead
    def self.find_action_from_name(name)
        return Roby.app.find_action_from_name(name)
    end

    # @deprecated use Roby.app.action_from_name instead
    def self.action_from_name(name)
        return Roby.app.action_from_name(name)
    end

    # @deprecated use Roby.app.prepare_action instead
    def self.prepare_action(plan, name, arguments = Hash.new)
        if plan != Roby.app.plan
            raise ArgumentError, "cannot call prepare_action with any other plan than Roby.app.plan"
        end
	return Roby.app.prepare_action(name, arguments)
    end

    # Implements that one can call
    #
    #   Robot.action_name! :arg0 => value0, :arg1 => value1
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
	task, planner = Roby.app.prepare_action(name, options)
	Roby.plan.add_mission(task)

	return task, planner
    end

    def self.init(&block)
        Roby.app.on_init(&block)
    end

    def self.requires(&block)
        Roby.app.on_require(&block)
    end

    def self.config(&block)
        Roby.app.on_config(&block)
    end

    def self.controller(&block)
        Roby.app.controller(&block)
    end

    def self.actions(&block)
        Roby.app.actions(&block)
    end
end

