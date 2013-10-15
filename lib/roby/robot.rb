require 'utilrb/logger'

module Robot
    class << self
	attr_accessor :logger
    end
    extend Logger::Forward

    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO
    @logger.formatter = Roby.logger.formatter
    @logger.progname = "Robot"

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
end

