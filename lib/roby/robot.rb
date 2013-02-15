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

    # Find an action on the planning interface that can generate the given task
    # model
    #
    # Raises ArgumentError if there either none or more than one. Otherwise,
    # returns the action name.
    def self.action_from_model(model)
	candidates = []
        Roby.app.planners.each do |planner_model|
            planner_model.find_all_actions_by_type(model).each do |action|
                candidates << [planner_model, action]
            end
        end
            
        if candidates.empty?
            raise ArgumentError, "cannot find an action to produce #{model}"
        elsif candidates.size > 1
            raise ArgumentError, "more than one actions available produce #{model}: #{candidates.map { |pl, m| "#{pl}.#{m.name}" }.sort.join(", ")}"
        else
            candidates.first
        end
    end
    
    # Find an action with the given name on the action interfaces registered on
    # Roby.app.planners
    #
    # @raise [ArgumentError] if no actions with that name exists, or if more
    #   than one action interface provide one
    def self.action_from_name(name)
        candidates = []
        Roby.app.planners.each do |planner_model|
            if m = planner_model.find_action_by_name(name)
                candidates << [planner_model, m]
            end
        end

        if candidates.empty?
            raise ArgumentError, "cannot find an action named #{name}"
        elsif candidates.size > 1
            raise ArgumentError, "more than one action interface provide the #{name} action: #{candidates.map { |pl, m| "#{pl}" }.sort.join(", ")}"
        else candidates.first
        end
    end

    # Generate the plan pattern that will call the required action on the
    # planning interface, with the given arguments.
    #
    # This returns immediately, and the action is not yet deployed at that
    # point.
    #
    # @return task, planning_task
    def self.prepare_action(plan, name, arguments = Hash.new)
        if name.kind_of?(Class)
            planner_model, m = action_from_model(name)
        else
            planner_model, m = action_from_name(name)
        end
        if plan
            plan.add(task = m.plan_pattern(arguments))
        end
	return task, task.planning_task
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
	task, planner = Robot.prepare_action(Roby.plan, name, options)
	Roby.plan.add_mission(task)

	return task, planner
    end
end

