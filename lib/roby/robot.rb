module Robot
    class << self
	attr_accessor :logger
    end
    extend Logger::Forward

    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO
    @logger.formatter = Roby.logger.formatter
    @logger.progname = "Robot"

    def self.prepare_action(plan, name, arguments)
	# Check if +name+ is a planner method, and in that case
	# add a planning method for it and plan it
	planner_model = Roby.app.planners.find do |planner_model|
	    planner_model.has_method?(name)
	end
	if !planner_model
	    raise ArgumentError, "no such planning method #{name}"
	end

	m = planner_model.model_of(name, arguments)
	returns_model = (m.returns if m && m.returns) || Roby::Task

	if returns_model.kind_of?(Roby::TaskModelTag)
	    task = Roby::Task.new
	    task.extend returns_model
	else
	    # Create an abstract task which will be planned
	    task = returns_model.new
	end

	planner = Roby::PlanningTask.new(:planner_model => planner_model, :method_name => name, :method_options => arguments)
        plan.add([task, planner])
	task.planned_by planner
	return task, planner
    end

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

